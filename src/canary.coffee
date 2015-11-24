_ = require 'lodash'
async = require 'async'
owner = require '../json/owner-local.json'
request = require 'request'
debug = (require 'debug')('octoblu-flow-canary:canary')

class Canary

  constructor: ({@meshbluConfig}={})->
    @jar = request.jar()
    @jar.setCookie request.cookie("meshblu_auth_uuid=#{owner.uuid}"), owner.apiHost
    @jar.setCookie request.cookie("meshblu_auth_token=#{owner.token}"), owner.apiHost

  message: (req, res) =>
    res.end()
    debug 'headers:', req.headers
    debug 'params:', req.params
    debug 'body:', req.body

  status: (req, res) =>
    res.json({goodStatus:true}).end()

  requestOctobluUrl: (method, path, callback) =>
    url = "#{owner.apiHost}#{path}"
    debug "getting octoblu url #{url}"
    request {method,url,@jar}, (error, response, body) =>
      debug 'get flows response:', response.statusCode
      callback body

  startFlows: () =>
    @requestOctobluUrl 'GET', '/api/flows', (result) =>
      flows = JSON.parse result
      stoppedFlows = _.filter flows, (flow) =>
        return !flow.activated

      startFlowFunction = (flow) =>
        debug 'starting', flow.name
        return (callback) =>
          @requestOctobluUrl 'POST', "/api/flows/#{flow.flowId}/instance", (result) =>
            debug 'started', flow.name, 'result:', result
            callback()

      flowsToStart = []

      _.each stoppedFlows, (flow) =>
        flowsToStart.push startFlowFunction(flow)

      async.series flowsToStart, =>
        debug 'all flows started'

      debug 'done starting flows'

module.exports = Canary
