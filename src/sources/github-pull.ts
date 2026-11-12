/** Pull request binding, lifecycle observation, and terminal IM notification helpers. */
import { z } from 'zod'
import { key, liveTicket, type Follow, type OutboundMessage, type ThreadFact, type Ticket } from '../core/index.ts'
import type { Deployment } from '../deployment.ts'
import { sameName } from '../infra/text.ts'
import { KV } from '../kv.ts'
import type { SourceContext } from './host.ts'
import { autoMergeTrigger, githubPage, SOURCE, UserSchema } from './github-trigger.ts'

const PullSchema = z.looseObject({
  title: z.string().optional(), state: z.string(), html_url: z.string(), user: UserSchema,
  body: z.string().nullish(), created_at: z.string().optional(),
  merged: z.boolean().optional(), merged_at: z.string().nullish(), closed_at: z.string().nullish(), auto_merge: z.unknown().optional(),
  // `mergeable` is null while GitHub computes it; `mergeable_state` names why, such as `dirty` for a conflict.
  mergeable: z.boolean().nullish(), mergeable_state: z.string().nullish(),
  head: z.looseObject({ sha: z.string(), ref: z.string(), repo: z.looseObject({ full_name: z.string() }).nullish() }),
})
export type Pull = z.infer<typeof PullSchema> & { number: number }
export const readPull = async (ctx: SourceContext, number: number, signal?: AbortSignal): Promise<Pull> =>
  ({ ...await ctx.commands.withSignal(signal).api(PullSchema, `pulls/${number}`), number })
const pullNumber = (thread: string): number | undefined => thread.startsWith(`${SOURCE}:`) ? Number(thread.slice(SOURCE.length + 1)) : undefined
export const pullsOf = (ticket: Pick<Ticket, 'follows'>, open = false): number[] =>
  (ticket.follows ?? []).filter(item => !open || !item.closed).flatMap(item => pullNumber(item.thread) ?? [])
export const pullOf = (ticket: Pick<Ticket, 'follows'>): number | undefined => pullsOf(ticket, true).at(-1) ?? pullsOf(ticket).at(-1)
/** True when the PR was opened by the agent account from a branch in the configured repository (not a fork). */
export const agentPull = (pr: { user: { login: string }; head?: { repo?: { full_name: string } | null } | null },
  deployment: Pick<Deployment, 'github' | 'repository'>): boolean =>
  sameName(pr.user.login, deployment.github.login) && sameName(pr.head?.repo?.full_name ?? '', deployment.repository)
/** True when a branch belongs to the ticket: its last path segment is the ticket's short name, such as `agent/<name>`. */
export const ticketBranch = (ticket: Pick<Ticket, 'execution'>, ref: string): boolean =>
  !!ticket.execution?.name && ref.split('/').at(-1) === ticket.execution.name
const AUTO_MERGE_ON: ThreadFact = { label: { zh: '自动合并', en: 'Auto-merge' }, value: { zh: '已开启', en: 'on' } }

/** What the operator allows an auto-merge to touch; the Source, not the Executor, decides whether a request stands. */
export interface AutoMergePolicy { autoMerge: boolean; autoMergePaths: string; autoMergeMaxFiles: number }
const PullFileSchema = z.looseObject({ filename: z.string() })
/** Splits the path list the panel stores: one per line or comma separated. */
export const autoMergePatterns = (value: string): string[] => value.split(/[\n,]/).map(item => item.trim()).filter(Boolean)
/** True when `path` matches a glob where `**` crosses directories and `*` stops at one. */
export function matchesPath(path: string, pattern: string): boolean {
  const source = pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*\*/g, '\u0000').replace(/\*/g, '[^/]*').replace(/\u0000/g, '.*')
  return new RegExp(`^${source}$`).test(path)
}
/**
 * Decides whether the auto-merge an Executor enabled may stand. The Executor can only request it: this withdraws the request
 * when the switch is off, when the change leaves the paths the operator listed, or when it touches more files than allowed,
 * and tells the Ticket why so it can shrink the change instead of waiting for a merge that will not happen.
 */
export async function enforceAutoMerge(ctx: SourceContext, number: number, pr: Pull, policy: AutoMergePolicy, signal?: AbortSignal): Promise<void> {
  const name = KV.github.autoMerge(number)
  const previous = ctx.state.get(name)
  const describe = (fact: ThreadFact | null): void => { ctx.threads.describe(`github:${number}`, { facts: { autoMerge: fact } }) }
  if (pr.auto_merge == null) {
    if (previous) { ctx.state.set(name, undefined); describe(null) }
    return
  }
  const files = await ctx.commands.withSignal(signal).api(z.array(PullFileSchema), `pulls/${number}/files?per_page=100`)
  const patterns = autoMergePatterns(policy.autoMergePaths)
  const outside = files.map(file => file.filename).filter(file => !patterns.some(pattern => matchesPath(file, pattern)))
  const listed = (names: string[]): string => names.slice(0, 3).join(', ') + (names.length > 3 ? ` and ${names.length - 3} more` : '')
  const reason = !policy.autoMerge ? 'auto-merge is switched off for this Source'
    : files.length > policy.autoMergeMaxFiles ? `it changes ${files.length} files, more than the ${policy.autoMergeMaxFiles} allowed`
    : outside.length ? `it changes ${listed(outside)}, outside the paths this Source may auto-merge`
    : undefined
  if (!reason) {
    if (previous?.verdict !== 'allowed') { ctx.state.set(name, { verdict: 'allowed', sha: pr.head.sha }); describe(AUTO_MERGE_ON) }
    return
  }
  if (previous?.verdict === 'revoked' && previous.sha === pr.head.sha) return
  ctx.state.set(name, { verdict: 'revoked', sha: pr.head.sha })
  describe({ label: { zh: '自动合并', en: 'Auto-merge' }, value: { zh: '已撤销', en: 'revoked' }, problem: true })
  // `--disable-auto` leaves the pull request open; a merge that already happened or a request GitHub no longer holds is fine.
  await ctx.commands.withSignal(signal).run(ctx.deployment.github.cli, ['pr', 'merge', String(number), '--disable-auto'])
    .catch(() => { /* Nothing left to withdraw. */ })
  await ctx.receive(autoMergeTrigger(pr, `Auto-merge on PR #${number} was withdrawn: ${reason}. `
    + 'The change stays open for a person to merge; shrink it into the allowed paths if it should merge without one.'))
}

/**
 * Validates and binds an open PR to a ticket when the PR is either the ticket's origin PR or an agent-authored PR on the ticket's branch, enforcing that one PR binds to at most one open ticket.
 * Returns an error message when binding is rejected, or undefined when the PR is bound or when the PR is not open (which is not an error).
 */
export function claimPull(ctx: SourceContext, ticketId: string, pr: Pull): string | undefined {
  const ticket = ctx.tickets.get(ticketId)
  if (!ticket || !liveTicket(ticket)) return 'Ticket ended because its PR was closed'
  const source = ctx.triggers.get(ticket.origin.triggerId)
  const started = source?.source === SOURCE && source.meta.isPr === true && source.meta.number === pr.number
  const opened = agentPull(pr, ctx.deployment) && ticketBranch(ticket, pr.head.ref)
  if (!started && !opened) {
    const { login } = ctx.deployment.github
    return `PR does not belong to this ticket: use the source PR or a PR by ${login} from a branch whose last path segment is DSH_SUPERAGENT_NAME; omit pr_number when no PR exists`
  }
  const owner = ctx.tickets.open().find(item => pullsOf(item, true).includes(pr.number))
  if (owner && owner.id !== ticketId) return 'PR already belongs to another active ticket'
  const follow = ticket.follows?.find(item => item.thread === `${SOURCE}:${pr.number}`)
  if (pr.state === 'open' && (!follow || follow.closed || (opened && !follow.own))) bind(ctx, ticketId, pr, opened)
  return undefined
}
/**
 * Reconciles a polled PR's open/merged/closed state and auto-merge fact with any bound or branch-matching ticket.
 * An open agent PR auto-binds to the single open ticket on its branch unless that ticket already follows another open PR
 * (which only the Executor's report changes).
 * @returns whether the PR has ended.
 */
export async function observePull(ctx: SourceContext, pr: Pull): Promise<boolean> {
  const ended = pr.state === 'closed' || !!pr.merged
  if (ended) closePull(ctx, pr)
  else {
    const candidates = agentPull(pr, ctx.deployment) ? ctx.tickets.open().filter(ticket => ticketBranch(ticket, pr.head.ref)) : []
    const ticket = candidates.length === 1 ? candidates[0]! : undefined
    // A PR the ticket followed until it closed, and that is open again, is followed again.
    const reopened = ticket?.follows?.some(item => item.thread === `${SOURCE}:${pr.number}` && item.closed)
    if (ticket && (reopened || pullsOf(ticket, true).every(number => number === pr.number))) claimPull(ctx, ticket.id, pr)
  }
  ctx.threads.describe(`github:${pr.number}`, { facts: { autoMerge: !ended && pr.auto_merge != null ? AUTO_MERGE_ON : null } })
  return ended
}
function bind(ctx: SourceContext, ticketId: string, pr: Pull, own: boolean): void {
  ctx.atomic(() => {
    ctx.tickets.bindThread(ticketId, { source: SOURCE, id: String(pr.number) }, own)
    ctx.threads.patch(`github:${pr.number}`, { number: pr.number, isPr: true, url: pr.html_url, prAuthor: pr.user.login })
  })
}
/**
 * Reports a merged or closed PR once to the open tickets that follow it, whose end the core decides.
 * Their subscription to the PR stays so a later human comment there resumes the ticket.
 */
function closePull(ctx: SourceContext, pr: Pull): void {
  if (!ctx.tickets.open().some(ticket => pullsOf(ticket, true).includes(pr.number))) return
  const at = pr.merged_at ?? pr.closed_at ?? new Date().toISOString()
  ctx.tickets.threadClosed({ source: SOURCE, id: String(pr.number) }, pr.merged ? 'merged' : 'closed', at)
}
/**
 * Builds idempotent outbound notices for IM conversations when a ticket ends with its PR (selecting the last-closed PR it
 * opened, else the last one it followed). The notice language follows the ticket's source request: Chinese when it contains
 * Han characters and no kana, otherwise English.
 */
export function pullEndNotices(ticket: Ticket, request: string, repository: string): OutboundMessage[] {
  const outcome = ticket.ended?.outcome
  const follows = (ticket.follows ?? []).filter(item => item.closed && pullNumber(item.thread) !== undefined)
  const latest = (items: Follow[]) => items.sort((a, b) => b.closed!.at.localeCompare(a.closed!.at))[0]
  const follow = latest(follows.filter(item => item.own)) ?? latest(follows)
  if ((outcome !== 'merged' && outcome !== 'closed') || !follow) return []
  const number = pullNumber(follow.thread)!
  const url = githubPage(repository, number, true)
  const chinese = /\p{Script=Han}/u.test(request) && !/[\p{Script=Hiragana}\p{Script=Katakana}]/u.test(request)
  const text = chinese
    ? outcome === 'merged' ? `[PR #${number}](${url}) 已合并。` : `[PR #${number}](${url}) 已关闭，未合并。`
    : outcome === 'merged' ? `[PR #${number}](${url}) has merged.` : `[PR #${number}](${url}) was closed without merging.`
  // GitHub timelines and linked issues already show the merge or closure, so GitHub channels are skipped.
  return ticket.channels.filter(channel => channel.source !== SOURCE).map(channel => ({
    id: key('pr-terminal', String(number), channel.source, JSON.stringify(channel.address), outcome), channel, text, kind: 'notice', ticketId: ticket.id }))
}
