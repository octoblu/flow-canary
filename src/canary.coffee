_ = require 'lodash'
async = require 'async'
request = require 'request'
debug = (require 'debug')('octoblu-flow-canary:canary')

class Canary

  constructor: ({@meshbluConfig}={})->
    @OCTOBLU_CANARY_UUID = process.env.OCTOBLU_CANARY_UUID
    @OCTOBLU_CANARY_TOKEN = process.env.OCTOBLU_CANARY_TOKEN
    @OCTOBLU_API_HOST = process.env.OCTOBLU_API_HOST or 'https://app.octoblu.com'
    @OCTOBLU_TRIGGER_HOST = process.env.OCTOBLU_TRIGGER_HOST or 'https://triggers.octoblu.com'

    # console.log 'OCTOBLU_CANARY_UUID:', @OCTOBLU_CANARY_UUID
    # console.log 'OCTOBLU_CANARY_TOKEN:', @OCTOBLU_CANARY_TOKEN
    # console.log 'OCTOBLU_API_HOST:', @OCTOBLU_API_HOST
    # console.log 'OCTOBLU_TRIGGER_HOST:', @OCTOBLU_TRIGGER_HOST

    unless @OCTOBLU_CANARY_UUID and @OCTOBLU_CANARY_TOKEN
      throw new Error 'Canary UUID or token not defined'

    @jar = request.jar()
    @jar.setCookie request.cookie("meshblu_auth_uuid=#{@OCTOBLU_CANARY_UUID}"), @OCTOBLU_API_HOST
    @jar.setCookie request.cookie("meshblu_auth_token=#{@OCTOBLU_CANARY_TOKEN}"), @OCTOBLU_API_HOST
    @stats = {flows:{}}
    setInterval @cleanupFlowStats, 1000*60
    setInterval @restartFailedFlows, 1000*60*5
    setInterval @postTriggers, 1000*60

  cleanupFlowStats: =>
    debug 'cleaning up flow stats'
    @getFlows (error, currentFlows) =>
      return console.error error if error?
      flowIds = {}
      _.each currentFlows, (flow) =>
        debug "has flow id #{flow.flowId}"
        flowIds[flow.flowId] = true
      _.each _.keys(@stats.flows), (flowUuid) =>
        if !flowIds[flowUuid]
          delete @stats.flows[flowUuid]

  restartFailedFlows: =>
    debug 'restarting failed flows'
    stats = @getCurrentStats()
    flowStarters = []
    _.each _.keys(stats.flows), (flowUuid) =>
      flowInfo = stats.flows[flowUuid]
      if !flowInfo.passing
        debug "restarting failed flow #{flowUuid}"
        flowStarters.push @curryStartFlow {flowId:flowUuid}
    async.series flowStarters

  postTriggers: =>
    debug 'posting triggers'
    @getActiveTriggers (error, triggers) =>
      return console.error error if error?
      _.each triggers, (trigger) =>
        flowInfo = @stats.flows[trigger.flowId] ?= {}
        triggerInfo = flowInfo.triggerTime ?= {}
        triggerTime = triggerInfo[trigger.triggerId] ?= []
        triggerTime.unshift Date.now()
        triggerInfo[trigger.triggerId] = triggerTime.slice(0,10)
        @postTriggerService trigger

  postMessage: (req, res) =>
    res.end()
    {fromUuid} = req.body
    flowInfo = @stats.flows[fromUuid] ?= {}
    flowInfo.messageTime ?= []
    flowInfo.messageTime.unshift Date.now()
    flowInfo.messageTime = flowInfo.messageTime.slice(0,10)

  getCurrentStats: =>
    _.each @stats.flows, (flowInfo) =>
      flowInfo.passing = false
      return unless flowInfo.messageTime
      flowInfo.timeDiff = Date.now() - flowInfo.messageTime[0]
      flowInfo.passing = true if flowInfo.timeDiff < 1000 * 90

    @stats.passing = _.keys(@stats.flows).length != 0
    _.each @stats.flows, (flowInfo) =>
      @stats.passing = false if !flowInfo.passing

    return @stats

  getStats: (req, res) =>
    res.json(@getCurrentStats()).end()

  getPassing: (req, res) =>
    res.end(JSON.stringify @getCurrentStats().passing)

  requestOctobluUrl: (method, path, callback) =>
    url = "#{@OCTOBLU_API_HOST}#{path}"
    debug "getting octoblu url #{url}"
    request {method,url,@jar}, (error, response, body) =>
      debug 'api response:', response.statusCode
      throw new Error "octoblu api error (code #{response.statusCode})" if response.statusCode >= 400
      callback error, body

  postTriggerService: (trigger, callback=->) =>
    url = "#{@OCTOBLU_TRIGGER_HOST}/flows/#{trigger.flowId}/triggers/#{trigger.triggerId}"
    debug "posting to trigger url #{url}"
    request {method:'POST',url}, (error, response, body) =>
      debug 'trigger response:', response.statusCode
      throw new Error "trigger error (code #{response.statusCode})" if response.statusCode >= 400
      callback error, body

  curryStartFlow: (flow) =>
    return (callback=->) =>
      # FIXME:
      #  Q: Remove the delay - why is it needed?
      #  A: Nanocyte-flow-deploy-service wants love.
      debug "starting #{flow.flowId}(#{flow.name})"
      _.delay =>
        @requestOctobluUrl 'POST', "/api/flows/#{flow.flowId}/instance", (error, body) =>
          debug "started #{flow.flowId}(#{flow.name}) body: #{body}"
          callback()
      , 3000

  startAllFlows: (callback=->) =>
    @getFlows (error, flows) =>
      return callback error if error?
      flowStarters = []
      _.each flows, (flow) => flowStarters.push @curryStartFlow(flow)
      async.series flowStarters, =>
        debug 'all flows started'
        callback()

  getFlows: (callback) =>
    @requestOctobluUrl 'GET', '/api/flows', (error, body) =>
      return callback error if error?
      return callback new Error 'body is undefined' unless body
      flows = JSON.parse body
      _.each flows, (flow) =>
        @stats.flows[flow.flowId] ?= {}
      callback null, flows

  getActiveTriggers: (callback=->) =>
    @getFlows (error, flows) =>
      return callback error if error?
      triggers = []
      _.each flows, (flow) =>
        triggerNodes = _.filter flow.nodes, (node) => return node.type == 'operation:trigger'
        _.each triggerNodes, (node) =>
          if flow.activated
            triggers.push { flowId: flow.flowId, triggerId: node.id }
            debug " - TRIGGER: #{flow.name} : #{node.name} (#{node.id})"
      callback(null, triggers)

module.exports = Canary
