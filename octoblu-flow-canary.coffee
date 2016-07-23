cors               = require 'cors'
morgan             = require 'morgan'
MessageController  = require './src/message-controller'
express            = require 'express'
bodyParser         = require 'body-parser'
errorHandler       = require 'errorhandler'
meshbluHealthcheck = require 'express-meshblu-healthcheck'
debug              = (require 'debug')('octoblu-flow-canary:express')
expressVersion     = require 'express-package-version'
compression        = require 'compression'
OctobluRaven       = require 'octoblu-raven'

cage = new MessageController
PORT = process.env.PORT ? 80
octobluRaven = new OctobluRaven
octobluRaven.patchGlobal()

app = express()
app.use compression()
app.use octobluRaven.express().handleErrors()
app.use meshbluHealthcheck()
app.use expressVersion(format: '{"version": "%s"}')
app.use cors()
skip = (request, response) =>
  return response.statusCode < 400
app.use morgan 'dev', {immediate: false, skip}
app.use errorHandler()
app.use bodyParser.urlencoded limit: '50mb', extended : true
app.use bodyParser.json limit : '50mb'

app.post '/message', cage.postMessage
app.get '/passing', cage.getPassing
app.get '/stats', cage.getStats

server = app.listen PORT, ->
  host = server.address().address
  port = server.address().port

  debug "Server running on #{host}:#{port}"

process.on 'SIGTERM', =>
  console.log 'SIGTERM caught, exiting'
  process.exit 0
