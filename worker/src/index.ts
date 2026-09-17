/**
 * relay-lite — the smallest relay that works.
 *
 * One MCP server, two tools: run_command queues a shell command for a runner
 * on your machine and waits for its result; get_result fetches a result the
 * wait missed. Nothing else. No Claude Code on the host, no panes, no mail.
 *
 * ###########################################################################
 * ##  This queues commands that a machine will EXECUTE as a real user.     ##
 * ##  Whoever can reach this Worker's URL can run arbitrary shell on the   ##
 * ##  runner host. Two things stand in the way:                            ##
 * ##                                                                       ##
 * ##   1. The URL secret. The MCP endpoint is /<RELAY_URL_SECRET>/mcp, and ##
 * ##      any other path is 404. Treat that URL like a password: it goes   ##
 * ##      into the connector settings of ONE assistant and nowhere else.   ##
 * ##   2. HMAC. Every row is signed with RELAY_HMAC_KEY, held only here    ##
 * ##      and on the runner. Database access alone cannot make the runner ##
 * ##      execute anything.                                                ##
 * ###########################################################################
 *
 * The signature is byte-for-byte the v1 scheme of tmux-relay's runner
 * (nonce + "\n" + command, HMAC-SHA256 keyed with the ASCII hex key), so
 * relay-lite.sh and tmux-relay's d1-runner.sh agree; tests/vectors.json in that
 * repo pins it.
 */

interface Env {
  DB: D1Database
  /** Hex key shared with the runner (relay.key). Set with `wrangler secret put`. */
  RELAY_HMAC_KEY: string
  /** The path secret. Set with `wrangler secret put`. */
  RELAY_URL_SECRET: string
  /** Seconds run_command waits by default / at most. */
  RELAY_WAIT_DEFAULT?: string
  RELAY_WAIT_MAX?: string
}

const PROTOCOL_VERSION = '2025-06-18'
const TERMINAL = ['done', 'error', 'rejected', 'timeout']
const MAX_COMMAND_CHARS = 8000

// --- signing (mirrors tmux-relay relay-sign.sh relay_hmac) -----------------
async function hmacHex(keyText: string, message: string): Promise<string> {
  const enc = new TextEncoder()
  // The key is the ASCII characters of the hex string, not the decoded bytes:
  // bash passes `-macopt key:$KEY`, which takes the literal text.
  const key = await crypto.subtle.importKey('raw', enc.encode(keyText), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = await crypto.subtle.sign('HMAC', key, enc.encode(message))
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('')
}
function randomHex(bytes: number): string {
  const a = new Uint8Array(bytes)
  crypto.getRandomValues(a)
  return [...a].map((b) => b.toString(16).padStart(2, '0')).join('')
}
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let d = 0
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return d === 0
}

// --- MCP -------------------------------------------------------------------
const TOOLS = [
  {
    name: 'run_command',
    description:
      "Run a shell command on the user's own machine and return its output. The " +
      'command is queued for a runner there, which executes it as the user with ' +
      'bash -lc, a 600 s limit and up to 60 KB of output kept; this call waits up ' +
      'to `wait` seconds for the result. Anything you send here RUNS on a real ' +
      "machine: prefer read-only commands unless the user asked for a change, and " +
      'never run something destructive on a guess.\n\n' +
      'How to operate it:\n' +
      '- The result starts with "#<id> <status> exit=<code>" then the output. ' +
      'Status done means it ran; check exit= before trusting the output.\n' +
      '- Commands run ONE AT A TIME in the order queued (unless the host set ' +
      'RELAY_PARALLEL), so a long command holds everything behind it.\n' +
      '- For anything that may take longer than the wait: pass a short wait, note ' +
      'the id you get back, and call get_result later. Or background it yourself ' +
      '(nohup ... > /tmp/job.log 2>&1 &) and read the log with a later command.\n' +
      '- Output over 60 KB is cut; pipe through head, tail or grep instead of ' +
      'dumping large files.\n' +
      '- There is no working directory or shell state between calls: each ' +
      "command starts fresh in the user's home. Use cd inside the command.\n" +
      '- Quote carefully: the string is passed to bash exactly as given.',
    inputSchema: {
      type: 'object',
      properties: {
        command: { type: 'string', description: 'The shell command, run with bash -lc from the home directory.' },
        wait: { type: 'number', description: 'Seconds to wait for the result (default 30, max 120). Use 0 to queue and return the id at once.' },
      },
      required: ['command'],
    },
  },
  {
    name: 'get_result',
    description:
      'Fetch the status and output of a command queued earlier, by the id run_command ' +
      'returned. Pass `wait` to block up to that many seconds until it finishes, so a ' +
      'long job needs one call rather than a polling loop; without it you get the ' +
      'current state at once. Status pending or running means it has not finished.',
    inputSchema: {
      type: 'object',
      properties: {
        id: { type: 'number', description: 'Row id from run_command.' },
        wait: { type: 'number', description: 'Seconds to wait for it to finish (default 0: answer now; max 120).' },
      },
      required: ['id'],
    },
  },
]

interface Row {
  id: number
  status: string
  exit_code: number | null
  output: string | null
}

function render(row: Row, timedOut: boolean): string {
  const head = `#${row.id} ${row.status}${row.exit_code === null ? '' : ` exit=${row.exit_code}`}`
  if (timedOut) return `${head}\nStill running after the wait. Call get_result(id=${row.id}) for the output.`
  return `${head}\n${row.output ?? ''}`
}

function rpc(id: unknown, result: unknown): Response {
  return Response.json({ jsonrpc: '2.0', id, result })
}
function rpcError(id: unknown, code: number, message: string): Response {
  return Response.json({ jsonrpc: '2.0', id, error: { code, message } })
}
function toolText(id: unknown, text: string, isError = false): Response {
  return rpc(id, { content: [{ type: 'text', text }], isError })
}

// Poll a row until it is terminal or the wait runs out. Shared by
// run_command and get_result, so "wait for it" means the same thing in
// both: 250 ms growing to 2 s between looks, and the wait is a ceiling.
async function awaitRow(env: Env, id: number, waitSeconds: number): Promise<{ row: Row | null; timedOut: boolean }> {
  const deadline = Date.now() + waitSeconds * 1000
  let delay = 250
  for (;;) {
    const row = await env.DB.prepare(`SELECT id, status, exit_code, output FROM commands WHERE id = ?`).bind(id).first<Row>()
    if (row && TERMINAL.includes(row.status)) return { row, timedOut: false }
    if (Date.now() >= deadline) return { row, timedOut: true }
    await new Promise((r) => setTimeout(r, Math.min(delay, Math.max(0, deadline - Date.now()))))
    delay = Math.min(Math.round(delay * 1.5), 2000)
  }
}

function clampWait(env: Env, asked: unknown, fallback: number): number {
  const max = Number(env.RELAY_WAIT_MAX ?? 120)
  const n = Number(asked ?? fallback)
  return Math.min(Math.max(Number.isFinite(n) ? n : fallback, 0), max)
}

async function enqueue(env: Env, command: string, waitSeconds: number): Promise<{ row: Row; timedOut: boolean }> {
  const nonce = randomHex(16)
  const sig = await hmacHex(env.RELAY_HMAC_KEY, `${nonce}\n${command}`)
  const ins = await env.DB.prepare(
    `INSERT INTO commands (command, status, sig, nonce, created_at, updated_at)
     VALUES (?, 'pending', ?, ?, datetime('now'), datetime('now'))`,
  )
    .bind(command, sig, nonce)
    .run()
  const id = Number(ins.meta.last_row_id)
  const r = await awaitRow(env, id, waitSeconds)
  return { row: r.row ?? { id, status: 'pending', exit_code: null, output: null }, timedOut: r.timedOut }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url)
    // The path IS the credential. Constant-time compare, and every miss is a
    // plain 404 so the endpoint cannot be found by probing.
    const parts = url.pathname.split('/').filter(Boolean)
    if (parts.length !== 2 || parts[1] !== 'mcp' || !env.RELAY_URL_SECRET || !timingSafeEqual(parts[0], env.RELAY_URL_SECRET)) {
      return new Response('not found', { status: 404 })
    }
    if (request.method !== 'POST') return new Response('POST JSON-RPC here', { status: 405 })

    let body: any
    try {
      body = await request.json()
    } catch {
      return rpcError(null, -32700, 'parse error')
    }
    const { method, id, params } = body ?? {}
    if (id === undefined || id === null) return new Response(null, { status: 202 }) // a notification

    switch (method) {
      case 'initialize':
        return rpc(id, {
          protocolVersion: typeof params?.protocolVersion === 'string' ? params.protocolVersion : PROTOCOL_VERSION,
          capabilities: { tools: {} },
          serverInfo: { name: 'relay-lite', version: '0.1.0' },
        })
      case 'ping':
        return rpc(id, {})
      case 'tools/list':
        return rpc(id, { tools: TOOLS })
      case 'tools/call': {
        const name = params?.name
        const args = params?.arguments ?? {}
        if (name === 'run_command') {
          const command = String(args.command ?? '')
          if (!command.trim()) return toolText(id, 'run_command needs a command.', true)
          if (command.length > MAX_COMMAND_CHARS) return toolText(id, `Command is ${command.length} characters; the limit is ${MAX_COMMAND_CHARS}.`, true)
          const wait = clampWait(env, args.wait, Number(env.RELAY_WAIT_DEFAULT ?? 30))
          const r = await enqueue(env, command, wait)
          return toolText(id, render(r.row, r.timedOut), !r.timedOut && ['error', 'rejected', 'timeout'].includes(r.row.status))
        }
        if (name === 'get_result') {
          const rid = Number(args.id)
          if (!Number.isInteger(rid)) return toolText(id, 'get_result needs a numeric id.', true)
          // Cece's suggestion (2026-09-17): let a check-back wait too, so one
          // call returns the moment the job finishes instead of the caller
          // polling by hand. Default 0 keeps the old immediate answer.
          const wait = clampWait(env, args.wait, 0)
          const r = await awaitRow(env, rid, wait)
          if (!r.row) return toolText(id, `No command #${rid}.`, true)
          return toolText(id, render(r.row, r.timedOut), ['error', 'rejected', 'timeout'].includes(r.row.status))
        }
        return rpcError(id, -32601, `unknown tool ${JSON.stringify(name)}`)
      }
      default:
        return rpcError(id, -32601, `unknown method ${JSON.stringify(method)}`)
    }
  },
}
