_ = require 'lodash'
async = require 'async'
request = require 'request'
debug = (require 'debug')('octoblu-flow-canary:canary')

class Canary

  constructor: ({@meshbluConfig}={})->

    @OCTOBLU_CANARY_UUID  = process.env.OCTOBLU_CANARY_UUID
    @OCTOBLU_CANARY_TOKEN = process.env.OCTOBLU_CANARY_TOKEN
    @OCTOBLU_API_HOST     = process.env.OCTOBLU_API_HOST     or 'https://app.octoblu.com'
    @OCTOBLU_TRIGGER_HOST = process.env.OCTOBLU_TRIGGER_HOST or 'https://triggers.octoblu.com'

    @CANARY_STATS_CLEANUP_INTERVAL = process.env.CANARY_STATS_CLEANUP_INTERVAL or 1000*60
    @CANARY_RESTART_FLOWS_INTERVAL = process.env.CANARY_RESTART_FLOWS_INTERVAL or 1000*60*5
    @CANARY_RESTART_FLOWS_MAX_TIME = process.env.CANARY_RESTART_FLOWS_MAX_TIME or 1000*60*3
    @CANARY_POST_TRIGGERS_INTERVAL = process.env.CANARY_POST_TRIGGERS_INTERVAL or 1000*60
    @CANARY_HEALTH_CHECK_MAX_TIME  = process.env.CANARY_HEALTH_CHECK_MAX_TIME  or 1000*90
    @CANARY_HISTORY_SIZE           = process.env.CANARY_HISTORY_SIZE           or 10

    # console.log 'OCTOBLU_CANARY_UUID:', @OCTOBLU_CANARY_UUID
    # console.log 'OCTOBLU_CANARY_TOKEN:', @OCTOBLU_CANARY_TOKEN
    # console.log 'OCTOBLU_API_HOST:', @OCTOBLU_API_HOST
    # console.log 'OCTOBLU_TRIGGER_HOST:', @OCTOBLU_TRIGGER_HOST

    unless @OCTOBLU_CANARY_UUID and @OCTOBLU_CANARY_TOKEN
      throw new Error 'Canary UUID or token not defined'

    @jar = request.jar()
    @jar.setCookie request.cookie("meshblu_auth_uuid=#{@OCTOBLU_CANARY_UUID}"), @OCTOBLU_API_HOST
    @jar.setCookie request.cookie("meshblu_auth_token=#{@OCTOBLU_CANARY_TOKEN}"), @OCTOBLU_API_HOST
    @stats =
      flows: {}
      startTime: Date.now()

    setInterval @cleanupFlowStats,   @CANARY_STATS_CLEANUP_INTERVAL
    setInterval @restartFailedFlows, @CANARY_RESTART_FLOWS_INTERVAL
    setInterval @postTriggers,       @CANARY_POST_TRIGGERS_INTERVAL

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
      if flowInfo.currentTimeDiff > @CANARY_RESTART_FLOWS_MAX_TIME
        console.error "restarting failed flow #{flowUuid}"
        flowStarters.push @curryStartFlow flowUuid
    async.series flowStarters

  postTriggers: (callback=->) =>
    debug 'posting triggers'
    @getActiveTriggers (error, triggers) =>
      return callback error if error?
      async.each triggers, (trigger, callback) =>
        flowInfo = @stats.flows[trigger.flowId] ?= {}
        triggerInfo = flowInfo.triggerTime ?= {}
        triggerTime = triggerInfo[trigger.triggerId] ?= []
        triggerTime.unshift Date.now()
        triggerInfo[trigger.triggerId] = triggerTime.slice(0,@CANARY_HISTORY_SIZE)
        @postTriggerService trigger, callback
      , callback

  postMessage: (req, res) =>
    res.end()
    {fromUuid} = req.body
    flowInfo = @stats.flows[fromUuid] ?= {}
    flowInfo.messageTime ?= []
    flowInfo.messageTime.unshift Date.now()
    flowInfo.messageTime = flowInfo.messageTime.slice(0,@CANARY_HISTORY_SIZE)
    flowInfo.timeDiffs ?= []
    if flowInfo.messageTime.length > 1
      flowInfo.timeDiffs.unshift flowInfo.messageTime[0] - flowInfo.messageTime[1]
    flowInfo.timeDiffs = flowInfo.timeDiffs.slice(0,@CANARY_HISTORY_SIZE)

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

  getStats: (req, res) =>
    res.json(@getCurrentStats()).end()

  getPassing: (req, res) =>
    res.end(JSON.stringify @getCurrentStats().passing)

  requestOctobluUrl: (method, path, callback) =>
    url = "#{@OCTOBLU_API_HOST}#{path}"
    debug "getting octoblu url #{url}"
    request {method,url,@jar}, (error, response, body) =>
      debug 'api response:', response.statusCode
      if response.statusCode >= 400
        console.error "octoblu api error (code #{response.statusCode})"
        return callback()
      callback error, body

  postTriggerService: (trigger, callback=->) =>
    url = "#{@OCTOBLU_TRIGGER_HOST}/flows/#{trigger.flowId}/triggers/#{trigger.triggerId}"
    debug "posting to trigger url #{url}"
    request {method:'POST',url}, (error, response, body) =>
      debug 'trigger response:', response.statusCode
      if response.statusCode >= 400
        console.error "trigger error (code #{response.statusCode})"
        return callback()
      callback error, body

  curryStartFlow: (flowUuid) =>
    return (callback=->) =>
      # FIXME:
      #  Q: Remove the delay - why is it needed?
      #  A: Nanocyte-flow-deploy-service wants love.
      debug "starting #{flowUuid}"
      _.delay =>
        @requestOctobluUrl 'POST', "/api/flows/#{flowUuid}/instance", (error, body) =>
          debug "started #{flowUuid} body: #{body}"
          flowInfo = @stats.flows[flowUuid]
          flowInfo.startTime ?= []
          flowInfo.startTime.unshift Date.now()
          callback()
      , 3000

  startAllFlows: (callback=->) =>
    @getFlows (error, flows) =>
      return callback error if error?
      flowStarters = []
      _.each flows, (flow) => flowStarters.push @curryStartFlow(flow.flowId)
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
        @stats.flows[flow.flowId].name = flow.name
        @stats.flows[flow.flowId].messageTime ?= [ Date.now() ]
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
