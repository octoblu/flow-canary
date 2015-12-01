_ = require 'lodash'
async = require 'async'
request = require 'request'
debug = (require 'debug')('octoblu-flow-canary:canary')

class Canary

  constructor: ->
    @OCTOBLU_CANARY_UUID  = process.env.OCTOBLU_CANARY_UUID
    @OCTOBLU_CANARY_TOKEN = process.env.OCTOBLU_CANARY_TOKEN
    @OCTOBLU_API_HOST     = process.env.OCTOBLU_API_HOST     or 'https://app.octoblu.com'
    @OCTOBLU_TRIGGER_HOST = process.env.OCTOBLU_TRIGGER_HOST or 'https://triggers.octoblu.com'

    @CANARY_UPDATE_INTERVAL        = process.env.CANARY_UPDATE_INTERVAL        or 1000*60
    @CANARY_RESTART_FLOWS_MAX_TIME = process.env.CANARY_RESTART_FLOWS_MAX_TIME or 1000*60*5
    @CANARY_HEALTH_CHECK_MAX_TIME  = process.env.CANARY_HEALTH_CHECK_MAX_TIME  or 1000*90
    @CANARY_HISTORY_SIZE           = process.env.CANARY_HISTORY_SIZE           or 10

    unless @OCTOBLU_CANARY_UUID and @OCTOBLU_CANARY_TOKEN
      throw new Error 'Canary UUID or token not defined'

    @jar = request.jar()
    @jar.setCookie request.cookie("meshblu_auth_uuid=#{@OCTOBLU_CANARY_UUID}"), @OCTOBLU_API_HOST
    @jar.setCookie request.cookie("meshblu_auth_token=#{@OCTOBLU_CANARY_TOKEN}"), @OCTOBLU_API_HOST
    @stats =
      flows: {}
      startTime: Date.now()
    @flows = []
    setInterval @processUpdateInterval,   @CANARY_UPDATE_INTERVAL

  processUpdateInterval: (callback=->) =>
    @getFlows =>
      @cleanupFlowStats()
      @restartFailedFlows =>
        @postTriggers callback

  messageFromFlow: (flowId) =>
    flowInfo = @stats.flows[flowId] ?= {}
    flowInfo.messageTime ?= []
    flowInfo.messageTime.unshift Date.now()
    flowInfo.messageTime = flowInfo.messageTime.slice(0,@CANARY_HISTORY_SIZE)
    flowInfo.timeDiffs ?= []
    if flowInfo.messageTime.length > 1
      flowInfo.timeDiffs.unshift flowInfo.messageTime[0] - flowInfo.messageTime[1]
    flowInfo.timeDiffs = flowInfo.timeDiffs.slice(0,@CANARY_HISTORY_SIZE)

  startAllFlows: (callback=->) =>
    @getFlows =>
      flowStarters = []
      _.each @flows, (flow) => flowStarters.push @curryStartFlow(flow.flowId)
      async.series flowStarters, =>
        debug 'all flows started'
        callback()

  cleanupFlowStats: =>
    debug 'cleaning up flow stats'
    flowIds = {}
    _.each @flows, (flow) =>
      debug "has flow id #{flow.flowId}"
      flowIds[flow.flowId] = true
    _.each _.keys(@stats.flows), (flowUuid) =>
      if !flowIds[flowUuid]
        delete @stats.flows[flowUuid]

  getCurrentStats: =>
    _.each @stats.flows, (flowInfo) =>
      flowInfo.passing = false
      return unless flowInfo.messageTime
      flowInfo.currentTimeDiff = Date.now() - flowInfo.messageTime[0]
      flowInfo.passing = true if flowInfo.currentTimeDiff < @CANARY_HEALTH_CHECK_MAX_TIME
      _.each flowInfo.timeDiffs, (timeDiff) =>
        flowInfo.passing = false if timeDiff >= @CANARY_HEALTH_CHECK_MAX_TIME

    @stats.passing = _.keys(@stats.flows).length != 0
    _.each @stats.flows, (flowInfo) =>
      @stats.passing = false if !flowInfo.passing

    return @stats

  getFlows: (callback) =>
    @requestOctobluUrl 'GET', '/api/flows', (error, body) =>
      return callback error if error?
      return callback new Error 'body is undefined' unless body
      @flows = JSON.parse body
      _.each @flows, (flow) =>
        @stats.flows[flow.flowId] ?= {}
        @stats.flows[flow.flowId].name = flow.name
      callback null, @flows

  getTriggers: =>
    triggers = []
    _.each @flows, (flow) =>
      triggerNodes = _.filter flow.nodes, (node) => return node.type == 'operation:trigger'
      _.each triggerNodes, (node) =>
        triggers.push { flowId: flow.flowId, triggerId: node.id }
        debug " - TRIGGER: #{flow.name} : #{node.name} (#{node.id})"
    return triggers

  restartFailedFlows: (callback=->) =>
    debug 'restarting failed flows'
    stats = @getCurrentStats()
    flowStarters = []
    _.each _.keys(stats.flows), (flowUuid) =>
      flowInfo = stats.flows[flowUuid]
      if flowInfo.currentTimeDiff > @CANARY_RESTART_FLOWS_MAX_TIME
        debug "restarting failed flow #{flowUuid}"
        flowStarters.push @curryStartFlow flowUuid
    async.series flowStarters, callback

  postTriggers: (callback=->) =>
    debug 'posting triggers'
    triggers = @getTriggers()
    async.each triggers, (trigger, callback) =>
      flowInfo = @stats.flows[trigger.flowId] ?= {}
      triggerInfo = flowInfo.triggerTime ?= {}
      triggerTime = triggerInfo[trigger.triggerId] ?= []
      triggerTime.unshift Date.now()
      triggerInfo[trigger.triggerId] = triggerTime.slice(0,@CANARY_HISTORY_SIZE)
      @postTriggerService trigger, callback
    , callback

  curryStartFlow: (flowUuid) =>
    return (callback=->) =>
      # FIXME:
      #  Q: Remove the delay - why is it needed?
      #  A: Nanocyte-flow-deploy-service wants love.
      debug "starting #{flowUuid}"
      _.delay =>
        @requestOctobluUrl 'POST', "/api/flows/#{flowUuid}/instance", (error, body) =>
          debug "started #{flowUuid} body: #{body}"
          currentTime = Date.now()
          flowInfo = @stats.flows[flowUuid]
          flowInfo.startTime ?= []
          flowInfo.startTime.unshift currentTime
          flowInfo.messageTime ?= [ currentTime ]
          callback()
      , 3000

  requestOctobluUrl: (method, path, callback) =>
    url = "#{@OCTOBLU_API_HOST}#{path}"
    debug "getting octoblu url #{url}"
    request {method,url,@jar}, (error, response, body) =>
      debug 'api response:', response.statusCode
      if response.statusCode >= 400
        debug "octoblu api error (code #{response.statusCode})"
        return callback new Error response.statusCode
      callback error, body

  postTriggerService: (trigger, callback=->) =>
    url = "#{@OCTOBLU_TRIGGER_HOST}/flows/#{trigger.flowId}/triggers/#{trigger.triggerId}"
    debug "posting to trigger url #{url}"
    request {method:'POST',url}, (error, response, body) =>
      debug 'trigger response:', response.statusCode
      if response.statusCode >= 400
        debug "trigger error (code #{response.statusCode})"
        return callback new Error response.statusCode
      callback error, body

module.exports = Canary
