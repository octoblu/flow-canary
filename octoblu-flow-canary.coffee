cors = require 'cors'
morgan = require 'morgan'
CanaryMessageController = require './src/canary/canary-message-controller'
express = require 'express'
bodyParser = require 'body-parser'
errorHandler = require 'errorhandler'
meshbluHealthcheck = require 'express-meshblu-healthcheck'
debug = (require 'debug')('octoblu-flow-canary:express')

cage = new CanaryMessageController
PORT = process.env.PORT ? 80

app = express()
app.use meshbluHealthcheck()
app.use cors()
app.use morgan 'dev'
app.use errorHandler()
app.use bodyParser.urlencoded limit: '50mb', extended : true
app.use bodyParser.json limit : '50mb'

app.post '/message', cage.postMessage
app.get '/passing', cage.getPassing
app.get '/stats', cage.getStats

startServer = (callback=->) =>
  server = app.listen PORT, ->
    host = server.address().address
    port = server.address().port
    debug "Server running on #{host}:#{port}"
    callback()

cage.canary.startAllFlows =>
  startServer =>
    cage.canary.postTriggers()

process.on 'SIGTERM', =>
  console.log 'SIGTERM caught, exiting'
  process.exit 0
