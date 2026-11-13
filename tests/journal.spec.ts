import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, it } from 'vitest'
import { Journal } from '../src/app/journal.ts'

let dir: string
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'journal-')) })
afterEach(() => { rmSync(dir, { recursive: true, force: true }) })
const created = (ticketId: string, at = '2026-09-23T00:00:00Z') =>
  ({ type: 'ticket.created' as const, at, data: { ticketId, decisionId: 'd1', strength: 'explicit' as const } })

it('appends each event as one line, in the order the domain saw it', () => {
  const file = join(dir, 'events.jsonl')
  const journal = new Journal(file)
  journal.write(created('t1'))
  journal.write({ type: 'group.ended', at: '2026-09-23T00:00:01Z', data: { decisionId: 'd1', parts: [] } })
  const lines = readFileSync(file, 'utf8').trim().split('\n').map(line => JSON.parse(line) as { type: string; data: { ticketId?: string } })
  expect(lines.map(line => line.type)).toEqual(['ticket.created', 'group.ended'])
  expect(lines[0]!.data.ticketId).toBe('t1')
})

it('rotates by size, keeps the recent past, and never loses the newest event', () => {
  const file = join(dir, 'events.jsonl')
  const journal = new Journal(file, 200, 2)
  for (let index = 0; index < 12; index += 1) journal.write(created(`t${index}`))
  expect(readdirSync(dir).sort()).toEqual(['events.jsonl', 'events.jsonl.1', 'events.jsonl.2'])
  expect(readFileSync(file, 'utf8')).toContain('t11')
})

it('does not throw when the file cannot be written, so the work it records goes on', () => {
  const journal = new Journal(join(dir, 'missing-dir', 'events.jsonl'))
  expect(() => journal.write(created('t1'))).not.toThrow()
})
