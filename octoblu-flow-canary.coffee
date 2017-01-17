MessageController  = require './src/message-controller'
octobluExpress     = require 'express-octoblu'
debug              = require('debug')('octoblu-flow-canary:express')


cage = new MessageController
PORT = process.env.PORT ? 80

app = octobluExpress({ bodyLimit: '50mb' })

app.post '/message', cage.postMessage
app.get '/passing', cage.getPassing
app.get '/stats', cage.getStats

server = app.listen PORT, ->
  host = server.address().address
  port = server.address().port

  debug "Canary running on #{host}:#{port}"

process.on 'SIGTERM', =>
  console.log 'SIGTERM caught, exiting'
  process.exit 0
