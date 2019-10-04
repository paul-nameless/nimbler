import asyncnet, asyncdispatch, strutils, httpcore, tables, json, sequtils
import logging


var logger = newConsoleLogger(fmtStr="[$time] - $levelname: ")
addHandler(logger)

const MAX_LEN = 4096
const HTTP1_1 = "HTTP/1.1"

var clients {.threadvar.}: seq[AsyncSocket]


type Context = object
  http_method: string
  path: string
  proto: string
  headers: HttpHeaders
  body: string
  conn: AsyncSocket


type Response = object
  status: int
  headers: HttpHeaders
  body: string

# declaration
proc textResp(text: string = "", status: int = 200, headers: HttpHeaders = newHttpHeaders()): Response

type Handler = object
  http_method: string
  fun: proc(ctx: Context): Future[Response]

var handlers = initTable[string, Handler]()


proc parseProto(line: string): seq[string] =
  return split(line, ' ')




proc reply(ctx: Context, resp: Response) {.async.} =
  await ctx.conn.send(ctx.proto & " " & $HttpCode(resp.status) & "\n")
  resp.headers["Content-Length"] = $resp.body.len

  for key, value in resp.headers:
    echo "Key: ", key
    let beautyKey = join(map(split(key, '-'), capitalizeAscii), "-")
    await ctx.conn.send(beautyKey & ": " & value & "\n")

  echo resp
  await ctx.conn.send("\n" & resp.body)

  ctx.conn.close()


proc processClient(conn: AsyncSocket) {.async.} =
  let line = await conn.recvLine(maxLength=MAX_LEN)
  let s = parseProto(line)
  let ctx = Context(http_method: s[0], path: s[1], proto: s[2], headers: newHttpHeaders(), conn: conn)

  if ctx.proto != HTTP1_1:
    echo ctx.proto, " protocol not supported"
    conn.close()
    return

  echo "Headers:"
  while true:
    let line = await conn.recvLine(maxLength=MAX_LEN)
    if line == "\r\n":
      echo "Headers end"
      break
    let (key, value) = parseHeader(line)
    ctx.headers[key] = value

  info(ctx)

  var resp: Response

  if not handlers.hasKey(ctx.path):
    await reply(ctx, textResp(status=404))
    return

  let handler = handlers[ctx.path]

  if handler.http_method != ctx.http_method:
    await reply(ctx, textResp(status=405))
    return

  resp = await handler.fun(ctx)
  await reply(ctx, resp)
  return


proc run() {.async.} =
  clients = @[]
  var server = newAsyncSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(5555), address="127.0.0.1")
  server.listen()

  while true:
    let ctx = await server.accept()
    clients.add ctx

    asyncCheck processClient(ctx)


proc htmlResp(html: string = "", status: int = 200, headers: HttpHeaders = newHttpHeaders()): Response =
  headers["content-type"] = "text/html"
  Response(status: status, body: html, headers: headers)


proc jsonResp(json: JsonNode, status: int = 200, headers: HttpHeaders = newHttpHeaders()): Response =
  headers["content-type"] = "application/json"
  Response(status: status, body: $json, headers: headers)


proc textResp(text: string = "", status: int = 200, headers: HttpHeaders = newHttpHeaders()): Response =
  headers["content-type"] = "text/plain"
  Response(status: status, body: text, headers: headers)

proc ping(ctx: Context): Future[Response] {.async.} =
  return textResp("pong")


proc getIp(ctx: Context): Future[Response] {.async.} =
  let ip = ctx.conn.getPeerAddr()[0]
  # return jsonResp(%* {"ip": $ip})
  return textResp($ip)


handlers["/ping"] = Handler(http_method: "GET", fun: ping)
handlers["/ip"] = Handler(http_method: "GET", fun: getIp)



type Server = object
  ip: string
  port: int
  handlers: TableRef[string, Handler]

proc run*(self: Server)

proc addHandler*(self: Server, http_method: string, path: string, fun: proc(ctx: Context): Future[Response]) =
  self.handlers[path] = Handler(http_method: "GET", fun: fun)

proc get*(self: Server, path: string, fun: proc(ctx: Context): Future[Response]) =
  self.addHandler("GET", path, fun)

proc newServer*(ip: string = "127.0.0.1", port: int = 5555): Server =
  return Server(ip: ip, port: port, handlers: newTable[string, Handler]())


when isMainModule:
  asyncCheck run()
  info("Server started...")
  runForever()
