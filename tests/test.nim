import
  asyncdispatch,
  httpClient,
  nimbler,
  unittest




suite "Test Nimbus":

  echo "Setup once:"
  var app = newApp()
  app.get(
    "/ping",
    proc(ctx: Context) {.async.} = await ctx.text("pong")
  )
  asyncCheck app.run

  setup:
    echo "Setup:"

  teardown:
    echo "Teardown:"

  test "ping":
    # let cli = newHttpClient()
    # let resp = cli.getContent("http://127.0.0.1:5555/ping")
    let cli = newAsyncHttpClient()
    let resp = waitFor cli.getContent("http://127.0.0.1:5555/ping")
    assert resp == "pong"

  echo "Teardown once:"
  # app.stop()
  # let cli = newHttpClient()
  # let resp = cli.getContent("http://127.0.0.1:5555/ping")
