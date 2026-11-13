/**
 * What the machine running the tests can actually do, so a test that needs a platform facility is skipped where the facility
 * is absent instead of failing there. A skip says "this could not run here"; a fix would say "the product is wrong", and the
 * two must not be confused when reading a red run.
 */
import { mkdirSync, mkdtempSync, rmSync, symlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

/** True where the POSIX shell, paths and process tools the suite was written against exist. */
export const posix = process.platform !== 'win32'

/**
 * Whether this account may create a symbolic link. Windows needs Developer Mode or an elevated process for it, so a suite
 * that links files has to ask rather than assume.
 */
export const symlinks = ((): boolean => {
  if (posix) return true
  const directory = mkdtempSync(join(tmpdir(), 'dsh-symlink-'))
  const target = join(directory, 'target')
  try {
    // Link a directory the way the suites do, without a type: a junction would succeed without the privilege this asks about.
    mkdirSync(target)
    symlinkSync(target, join(directory, 'link'))
    return true
  } catch {
    return false
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})()

/** The reason a suite is skipped here, for the message a reader sees. */
export const noSymlinks = 'this platform cannot create symbolic links without Developer Mode'

