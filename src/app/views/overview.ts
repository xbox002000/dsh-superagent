/** Overview view: active system problems, tickets awaiting human action, executor load, and 24-hour trigger flow. */
import { reasonText, ticketStage, type Decision, type Thread } from '../../core/index.ts'
import type { Health } from '../../sources/host.ts'
import type { SetupProblem } from '../../setup.ts'
import { anyoneAllowed } from '../../policy.ts'
import type { Store } from '../store.ts'
import { awaitingEval, dayAgo, newestFirst, ownersOf, snapshot, threadSummary, type ViewHost } from './records.ts'
import { sourceHealth, type HealthMap } from './sources.ts'
import { ticketRow, type ExecutorLoad } from './tickets.ts'
import { preview } from './text.ts'

/** Threads whose latest decision since `since` is an undismissed `unavailable` eval and that are neither evaluating nor queued. */
function unjudged(store: Store, since: string): { thread: Thread; decision: Decision }[] {
  const seen = new Set<string>()
  const queue = { store, owners: ownersOf(store) }
  return store.read.decisionsOfKinds(['unavailable'], 200).filter(decision => decision.at >= since).flatMap(decision => {
    if (seen.has(decision.threadKey)) return []
    seen.add(decision.threadKey)
    const thread = store.threads.get(decision.threadKey)
    if (!thread || thread.evaluating || awaitingEval(queue, thread).length || decision.dismissed) return []
    if (store.decisions.byThread(thread.key).at(-1)?.id !== decision.id) return []
    return [{ thread, decision }]
  })
}
/** Reports error health when any thread has an undismissed `unavailable` eval from the last hour without a newer decision or active eval. */
export function evalsHealth(store: Store, now = Date.now()): Health {
  const since = new Date(now - 3_600_000).toISOString()
  const open = unjudged(store, since)
  if (!open.length) return { state: 'ready', detail: 'No unavailable Eval in the last hour' }
  const latest = open[0]!.decision
  return { state: 'error', at: latest.at, detail: `${open.length} Eval(s) unavailable in the last hour without a later judgement; `
    + `the latest on ${latest.threadKey}: ${reasonText(latest.reason)}` }
}
/**
 * How the assessments turned out, so the rules can be tuned from evidence instead of guessed at. A Ticket a person closed
 * or stopped after it was accepted is an accept that should not have been made; a Thread that later carries an accepted
 * decision was work an ignore turned away and a person pushed through anyway.
 */
function calibration(store: Store, limit = 200) {
  const accepted = store.read.decisionsOfKinds(['accept'], limit)
  const ignored = store.read.decisionsOfKinds(['ignore'], limit)
  const turnedDown = accepted.filter(decision => {
    const outcome = decision.ticketId ? store.tickets.get(decision.ticketId)?.ended?.outcome : undefined
    return outcome === 'closed' || outcome === 'stopped'
  })
  const laterWorked = ignored.filter(decision => store.decisions.byThread(decision.threadKey)
    .some(other => other.id !== decision.id && other.kind === 'accept' && other.at > decision.at))
  // The cases behind the counts, newest first, so an operator can read what went wrong and open the thread.
  const cases = [
    ...turnedDown.map(decision => ({ decision, verdict: 'accept-turned-down' as const })),
    ...laterWorked.map(decision => ({ decision, verdict: 'ignore-later-worked' as const })),
  ].sort((left, right) => right.decision.at.localeCompare(left.decision.at)).slice(0, 10)
  return { accepted: accepted.length, acceptedTurnedDown: turnedDown.length, ignored: ignored.length, ignoredLaterWorked: laterWorked.length,
    recent: cases.map(({ decision, verdict }) => ({ at: decision.at, threadKey: decision.threadKey, verdict,
      reason: reasonText(decision.reason), ...decision.ticketId ? { ticketId: decision.ticketId } : {} })) }
}
/**
 * Builds the operator overview: active system problems, tickets awaiting human action, executor load, and 24-hour trigger flow.
 * @param setup - Setup problem to surface first (where setup stopped, or a Source paused by setup).
 */
export function overview(host: ViewHost, health: HealthMap, policyVersionValue: string, load: ExecutorLoad, setup?: SetupProblem) {
  const { store, sources } = host
  const view = snapshot(host)
  const settings = store.settings()
  const now = new Date().toISOString(), since = dayAgo()
  const evaluating = store.threads.active().filter(thread => thread.evaluating)
  const instances = sources.instances()
  const running = instances.filter(instance => instance.enabled && instance.installed).map(instance => sourceHealth(sources, instance, health))
  // Exclude source-owned and policy-sync health entries so only core runtime errors surface as `runtime-error`.
  const sourceParts = new Set(instances.flatMap(instance => sources.kind(instance.kind)?.health ?? []))
  const problems = [
    ...(setup ? [{ kind: 'setup' as const, ...setup }] : []),
    ...(running.length ? [] : [{ kind: 'no-source' as const }]),
    // Only allowed senders can originate work, so empty allowlists mean no request can ever become a ticket.
    ...(anyoneAllowed(settings) ? [] : [{ kind: 'no-allowed' as const }]),
    ...running.flatMap(source => source.health.filter(item => item.state === 'error').map(item => ({ kind: 'source-error' as const, source: { id: source.id, title: source.title, health: item } }))),
    ...(settings.paused ? [{ kind: 'executor-paused' as const }] : []),
    // Unavailable Evals behind the `evals` health entry are listed individually as `eval-unavailable` below.
    ...Object.entries(health).filter(([name, item]) => item.state === 'error' && !sourceParts.has(name) && !name.startsWith('sync:')
      && name !== 'evals')
      .map(([name, item]) => ({ kind: 'runtime-error' as const, name, detail: item.detail })),
    ...evaluating.filter(thread => thread.evaluating!.deadline < now)
      .map(thread => ({ kind: 'eval-overdue' as const, thread: threadSummary(view, thread) })),
    ...unjudged(store, since).map(({ thread, decision }) => ({ kind: 'eval-unavailable' as const, decisionId: decision.id,
      thread: threadSummary(view, thread), reason: decision.reason, triggerId: decision.triggerIds[0] ?? '' })),
    ...store.read.failingReplies().map(item => ({ kind: 'outgoing' as const, outgoing: { id: item.id, channel: item.channel,
      text: preview(item.text),
      attempts: item.attempts, error: item.error } })),
  ]
  const open = store.tickets.open().sort(newestFirst)
  const stats = Object.values(store.read.triggerStats(since))
  const received = stats.reduce((sum, item) => sum + item.received, 0), filtered = stats.reduce((sum, item) => sum + item.filtered, 0)
  const judgement = store.read.flow(since)
  return {
    problems,
    person: open.filter(ticket => ticketStage(ticket).stage === 'person').map(ticket => ticketRow(view, ticket)),
    executor: { ...load, maxWorkers: settings.executor.maxWorkers, idle: open.filter(ticket => ticketStage(ticket).stage === 'idle').length },
    flow: { received, filtered, triggers: received - filtered, judged: judgement.judged, accepted: judgement.accepted,
      evaluating: evaluating.length, dropped: store.read.droppedSince(since) },
    policyVersion: policyVersionValue,
    calibration: calibration(store),
  }
}
export type OverviewView = ReturnType<typeof overview>
