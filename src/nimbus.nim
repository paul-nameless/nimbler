import
  asyncdispatch,
  asyncnet,
  httpcore,
  json,
  logging,
  os,
  sequtils,
  strutils,
  tables
from htmlgen import nil


var logger = newConsoleLogger(fmtStr="[$time] - $levelname: ")
addHandler(logger)

const MAX_LEN = 4096
const HTTP1_1 = "HTTP/1.1"

var clients {.threadvar.}: seq[AsyncSocket]


type Context* = object
  http_method*: string
  path*: string
  proto*: string
  headers*: HttpHeaders
  body*: string
  conn*: AsyncSocket
  query*: TableRef[string, string]
  form*: TableRef[string, string]
  # json*: TableRef[string, string]


proc getPeer*(self: Context): (string, Port) = self.conn.getPeerAddr()


# proc set*(self: Context, key, value: string) = discard
# proc get*(self: Context, key: string): string = discard


proc send*(self: Context, body: string = "", status: int = 200, headers: HttpHeaders = nil) {.async.} =
  await self.conn.send(self.proto & " " & $HttpCode(status) & "\n")

  let headers = if headers == nil: newHttpHeaders() else: headers

  headers["Content-Length"] = $body.len

  for key, value in headers:
    let beautyKey = join(map(split(key, '-'), capitalizeAscii), "-")
    await self.conn.send(beautyKey & ": " & value & "\n")

  await self.conn.send("\n" & body)

  # TODO: we should close at the end, when handling finished
  self.conn.close()



proc text*(self: Context, body: string = "", status: int = 200, headers: HttpHeaders = nil) {.async.} =
  let headers = if headers == nil: newHttpHeaders() else: headers
  headers["content-type"] = "text/plain"
  await self.send(body, status, headers)


proc file*(self: Context, filePath: string = "", status: int = 200, headers: HttpHeaders = nil) {.async.} =
  let headers = if headers == nil: newHttpHeaders() else: headers
  headers["content-type"] = "application/octet-stream"
  let body = readFile(filePath)
  await self.send(body, status, headers)


proc html*(self: Context, body: string = "", status: int = 200, headers: HttpHeaders = nil) {.async.} =
  let headers = if headers == nil: newHttpHeaders() else: headers
  headers["content-type"] = "text/html"
  await self.send(body, status, headers)


proc json*(self: Context, body: JsonNode, status: int = 200, headers: HttpHeaders = nil) {.async.} =
  let headers = if headers == nil: newHttpHeaders() else: headers
  headers["content-type"] = "application/json"
  await self.send($body, status, headers)


proc parseProto(line: string): seq[string] =
  return split(line, ' ')


type App = object
  is_stopped: bool
  server*: AsyncSocket
  handlers: TableRef[
    string,
    TableRef[string, proc(ctx: Context): Future[void]]
  ]
  prefixHandlers: TableRef[
    string, proc(ctx: Context): Future[void]
  ]

proc newApp*(): App =
  return App(
    server: newAsyncSocket(),
    handlers: newTable[string, TableRef[string, proc(ctx: Context): Future[void]]](),
    prefixHandlers: newTable[string, proc(ctx: Context): Future[void]]()
  )


proc processClient(self: App, conn: AsyncSocket) {.async.} =
  let line = await conn.recvLine(maxLength=MAX_LEN)
  let s = parseProto(line)
  let ctx = Context(http_method: s[0], path: s[1], proto: s[2], headers: newHttpHeaders(), conn: conn)

  if ctx.proto != HTTP1_1:
    conn.close()
    return

  while true:
    let line = await conn.recvLine(maxLength=MAX_LEN)
    if line == "\r\n":
      break
    let (key, value) = parseHeader(line)
    ctx.headers[key] = value

  info(ctx)

  for prefix, handler in self.prefixHandlers:
    if ctx.path.startsWith(prefix):
      await handler(ctx)
      return

  if not self.handlers.hasKey(ctx.path):
    await ctx.text(status=404)
    return

  if not self.handlers[ctx.path].hasKey(ctx.http_method):
    await ctx.text(status=405)
    return

  await self.handlers[ctx.path][ctx.http_method](ctx)


var is_stopped = false

proc run*(self: App) {.async.} =
  clients = @[]
  self.server.setSockOpt(OptReuseAddr, true)
  self.server.bindAddr(Port(5555), address="127.0.0.1")
  self.server.listen()

  while not is_stopped:
    echo "waiting for connection"
    let conn = await self.server.accept()
    clients.add conn
    echo "get conn"

    asyncCheck self.processClient(conn)


proc stop*(app: App) =
  is_stopped = true
  # app.server.close()


proc addHandler*(self: App, http_method: string, path: string, fun: proc(ctx: Context): Future[void]) =
  if not self.handlers.hasKey(path):
    self.handlers[path] = newTable[string, proc(ctx: Context): Future[void]]()

  self.handlers[path][http_method] = fun



proc get*(self: App, path: string, fun: proc(ctx: Context): Future[void]) =
  self.addHandler("GET", path, fun)


proc redirect*(url: string): proc(ctx: Context): Future[void] =
    return proc(ctx: Context): Future[void] =
               ctx.send(status=303, headers=newHttpHeaders({"Location": url}))


proc staticHandler(ctx: Context, prefix, dirPath: string, showDirs: bool = false) {.async.} =
  let path = ctx.path.replace(prefix, "")
  let fullPath = joinPath(dirPath, path)

  if fileExists(fullPath):
    await ctx.file(fullPath)
  elif showDirs and dirExists(fullPath):
    var listOfFiles = ""
    for elem in walkPattern(joinPath(dirPath, path, "*")):
      let filename = splitPath(elem).tail
      listOfFiles.add(htmlgen.li(htmlgen.a(filename, href=joinPath(prefix, path, filename))))
    let page = htmlgen.html(
      htmlgen.head(htmlgen.title(path)),
      htmlgen.body(
        htmlgen.h1("Directory listing for: " & path),
        htmlgen.hr(),
        htmlgen.ul(listOfFiles),
        htmlgen.hr()
      )
    )
    await ctx.html(page)
  else:
    await ctx.text("File not found", status=404)


proc addStatic*(self: App, prefix: string, dirPath: string, showDirs: bool = false) =
  if self.prefixHandlers.hasKey(prefix):
    error("prefix already exists")
    quit 1
  self.prefixHandlers[prefix] =
    proc(ctx: Context): Future[void] =
      staticHandler(ctx, dirPath, prefix, showDirs)


proc decodeQuery*(queries: string): TableRef[string, string] =
  result = newTable[string, string]()
  for query in queries.split("&"):
    let keyVal = query.split("=", 1)
    if keyVal.len < 2:
      continue
    result[keyVal[0]] = keyVal[1]
