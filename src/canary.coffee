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
      debug 'request response:', response.statusCode
      callback error, body

  curryStartFlow: (flow) =>
    return (callback=->) =>
      # FIXME:
      #  Q: Remove the delay - why is it needed?
      #  A: Nanocyte-flow-deploy-service wants love.
      debug 'starting', flow.name
      _.delay =>
        @requestOctobluUrl 'POST', "/api/flows/#{flow.flowId}/instance", (error, body) =>
          debug 'started', flow.name, 'body:', body
          callback()
      , 5000

  startFlows: (callback=->) =>
    @getFlows (error, flows) =>
      flowStarters = []
      stoppedFlows = _.filter flows, (flow) => return !flow.activated
      _.each stoppedFlows, (flow) => flowStarters.push @curryStartFlow(flow)
      async.series flowStarters, =>
        debug 'all flows started'
        callback()

  getFlows: (callback) =>
    @requestOctobluUrl 'GET', '/api/flows', (error, body) =>
      callback error if error?
      flows = JSON.parse body
      callback null, flows

  getTriggers: (callback=->) =>
    @getFlows (error, flows) =>
      _.each flows, (flow) =>
        triggerNodes = _.filter flow.nodes, (node) => return node.type == 'operation:trigger'
        _.each triggerNodes, (node) =>
          debug " - TRIGGER: #{flow.name} : #{node.name} (#{node.id})"
      callback()

module.exports = Canary
