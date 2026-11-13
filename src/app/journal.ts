/**
 * The journal: every domain event appended to a JSON lines file beside the state, so a week of running can be read back after
 * the fact. A Ticket released, a split reported, a merge withdrawn — each is one line with the time it happened.
 *
 * The file rotates by size rather than by day: a quiet installation should not accumulate empty files, and a busy one should
 * not grow without a bound. A write that fails never stops the work it was recording.
 */
import { appendFileSync, existsSync, readFileSync, renameSync, statSync } from 'node:fs'
import type { DomainEvent } from '../core/index.ts'

/** Appends every domain event to a JSON lines file beside the state, rotating it by size. */
export class Journal {
  constructor(private readonly file: string, private readonly limit = 8 * 1024 * 1024, private readonly keep = 3) {}

  /** Appends one event; a failure to write is swallowed, because the journal describes the work and must not stop it. */
  write(event: DomainEvent): void {
    try {
      this.rotate()
      appendFileSync(this.file, `${JSON.stringify(event)}\n`, 'utf8')
    } catch { /* The disk is full or the file is locked; the work goes on without a record of this event. */ }
  }

  /** The last `limit` events in the file, oldest first; a line that does not parse is skipped rather than fatal. */
  read(limit = 200): DomainEvent[] {
    try {
      const lines = readFileSync(this.file, 'utf8').split('\n').filter(Boolean)
      return lines.slice(-limit).flatMap(line => {
        try { return [JSON.parse(line) as DomainEvent] } catch { return [] }
      })
    } catch { return [] }
  }

  /** Renames the file to `.1` once it passes `limit`, shifting the older ones, so `keep` files cover the recent past. */
  private rotate(): void {
    if (!existsSync(this.file) || statSync(this.file).size < this.limit) return
    for (let index = this.keep - 1; index >= 1; index -= 1) {
      const from = `${this.file}.${index}`
      if (existsSync(from)) renameSync(from, `${this.file}.${index + 1}`)
    }
    renameSync(this.file, `${this.file}.1`)
  }
}
