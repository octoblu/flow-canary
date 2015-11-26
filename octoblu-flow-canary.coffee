cors = require 'cors'
morgan = require 'morgan'
Canary = require './src/canary'
express = require 'express'
bodyParser = require 'body-parser'
errorHandler = require 'errorhandler'
meshbluHealthcheck = require 'express-meshblu-healthcheck'
debug = (require 'debug')('octoblu-flow-canary:express')

canary = new Canary
PORT = process.env.PORT ? 80

app = express()
app.use cors()
app.use morgan 'dev'
app.use errorHandler()
app.use meshbluHealthcheck()
app.use bodyParser.urlencoded limit: '50mb', extended : true
app.use bodyParser.json limit : '50mb'

app.post '/message', canary.postMessage
app.get '/passing', canary.getPassing
app.get '/stats', canary.getStats

startServer = (callback=->) =>
  server = app.listen PORT, ->
    host = server.address().address
    port = server.address().port
    debug "Server running on #{host}:#{port}"
    callback()

canary.startAllFlows =>
  startServer =>
    canary.postTriggers()
