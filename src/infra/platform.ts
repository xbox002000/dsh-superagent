/**
 * Platform differences in one place: what an absolute path looks like, which shell tool DSH registers, and how worker CLI
 * shims are written. Everything Windows-specific that used to be scattered across deployment, policy, sessions and the
 * environment lives here, so a fix or a new platform touches this file instead of four.
 */
import { join } from 'node:path'

export const WINDOWS = process.platform === 'win32'

/** A POSIX absolute path, a Windows drive path (`C:\…` or `C:/…`), or a UNC path (`\\server\share`). */
export const ABSOLUTE_PATH = /^(\/|[A-Za-z]:[\\/]|\\\\)/

/** True for a path this platform accepts as absolute; `''` is not absolute anywhere. */
export const isAbsolutePath = (path: string): boolean => ABSOLUTE_PATH.test(path)

/**
 * The shell tool DSH registers in a Session: `bash` on POSIX and `pwsh` on Windows. A restriction that names a tool the
 * Session cannot see is refused, so callers ask which one it has rather than assuming.
 */
export const SHELL_TOOLS: readonly string[] = ['bash', 'pwsh']

/** Name of the file a worker CLI shim is written to: cmd resolves `gh` through PATHEXT, so Windows needs `gh.cmd`. */
export const shimFile = (name: string): string => WINDOWS ? `${name}.cmd` : name

/** The ownership marker as the platform's shell reads it: `#` starts a comment in sh, and `REM` does in cmd. */
export const shimMarker = (marker: string): string => WINDOWS ? `REM ${marker}` : marker

/** Whether a line read from a shim file carries `marker`; Windows prefixes it with `REM`, and CRLF leaves a `\r`. */
export const carriesMarker = (line: string, marker: string): boolean =>
  line.replace(/\r$/, '').replace(/^REM\s+/, '') === marker

/** Joins a temporary shim path the way this platform names files. */
export const shimTemporary = (dir: string, file: string, pid: number): string => join(dir, `.${file}.${pid}.tmp`)

/**
 * Body of a shim that runs `program` with the caller's arguments and `dir` removed from PATH, so a wrapper that resolves
 * `gh` by name reaches the real binary. Windows cannot rewrite an environment variable, so its PATH is baked in and `env`
 * entries are exported with `set`; POSIX strips the directory at run time.
 */
export function runShim(program: string, dir: string, path: string, env: Record<string, string>): string {
  if (WINDOWS) {
    return ['@echo off', `set "PATH=${path}"`, ...Object.entries(env).map(([name, value]) => `set "${name}=${value}"`), `"${program}" %*`]
      .join('\r\n')
  }
  const quote = (value: string): string => `'${value.replaceAll("'", "'\\''")}'`
  const withoutShims = [
    `self=${quote(dir)}`, 'rest=', 'IFS=:', 'set -f',
    'for entry in $PATH; do [ "$entry" = "$self" ] || rest="${rest:+$rest:}$entry"; done',
    'set +f', 'unset IFS', 'PATH=$rest', 'export PATH',
  ]
  return [...withoutShims, ...Object.entries(env).map(([name, value]) => `${name}=${quote(value)}; export ${name}`),
    `exec ${quote(program)} "$@"`].join('\n')
}

/** Body of a shim that refuses to run: it prints `message` on standard error and exits non-zero. */
export function failShim(message: string): string {
  if (WINDOWS) {
    const escape = (value: string): string => value.replaceAll('%', '%%').replace(/[&|<>^]/g, character => `^${character}`)
    return ['@echo off', `echo ${escape(message)} 1>&2`, 'exit /b 1'].join('\r\n')
  }
  return `echo '${message.replaceAll("'", "'\\''")}' >&2\nexit 1`
}

/**
 * How a startup probe runs `argv` with `path` as PATH: Windows has no `env` command, so the value goes through the child
 * environment, while POSIX prefixes the command with `env PATH=…` so the probe keeps the caller's other variables.
 */
export function probeInvocation(argv: string[], path: string): { argv: string[]; env?: Record<string, string> } {
  if (!WINDOWS) return { argv: ['env', `PATH=${path}`, ...argv] }
  const env = Object.fromEntries(Object.entries(process.env).filter(([, value]) => value !== undefined)) as Record<string, string>
  return { argv, env: { ...env, PATH: path } }
}
