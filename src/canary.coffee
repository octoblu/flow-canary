_ = require 'lodash'
async = require 'async'
request = require 'request'
debug = (require 'debug')('octoblu-flow-canary:canary')

class Canary

  constructor: ({@Date}={})->
    @Date ?= Date

    @OCTOBLU_CANARY_UUID  = process.env.OCTOBLU_CANARY_UUID
    @OCTOBLU_CANARY_TOKEN = process.env.OCTOBLU_CANARY_TOKEN
    @OCTOBLU_API_HOST     = process.env.OCTOBLU_API_HOST     or 'https://app.octoblu.com'
    @OCTOBLU_TRIGGER_HOST = process.env.OCTOBLU_TRIGGER_HOST or 'https://triggers.octoblu.com'

    @CANARY_RESTART_FLOWS_MAX_TIME = Number.parseInt(process.env.CANARY_RESTART_FLOWS_MAX_TIME) or 1000*60*5
    @CANARY_UPDATE_INTERVAL        = Number.parseInt(process.env.CANARY_UPDATE_INTERVAL)        or 1000*60
    @CANARY_HEALTH_CHECK_MAX_DIFF  = Number.parseInt(process.env.CANARY_HEALTH_CHECK_MAX_DIFF)  or 1000
    @CANARY_DATA_HISTORY_SIZE      = Number.parseInt(process.env.CANARY_DATA_HISTORY_SIZE)      or 5
    @CANARY_ERROR_HISTORY_SIZE     = Number.parseInt(process.env.CANARY_ERROR_HISTORY_SIZE)     or 20

    unless @OCTOBLU_CANARY_UUID and @OCTOBLU_CANARY_TOKEN
      throw new Error 'Canary UUID or token not defined'

    @jar = request.jar()
    @jar.setCookie request.cookie("meshblu_auth_uuid=#{@OCTOBLU_CANARY_UUID}"), @OCTOBLU_API_HOST
    @jar.setCookie request.cookie("meshblu_auth_token=#{@OCTOBLU_CANARY_TOKEN}"), @OCTOBLU_API_HOST
    @stats =
      flows: {}
      startTime: @Date.now()
    @flows = []

    setInterval @processUpdateInterval, @CANARY_UPDATE_INTERVAL

  timeDiffGreaterThanMin: (timeDiff) =>
    return timeDiff >= (@CANARY_UPDATE_INTERVAL - @CANARY_HEALTH_CHECK_MAX_DIFF)

  timeDiffLessThanMax: (timeDiff) =>
    return timeDiff <= (@CANARY_UPDATE_INTERVAL + @CANARY_HEALTH_CHECK_MAX_DIFF)

  passingTimeDiff: (timeDiff) =>
    return @timeDiffGreaterThanMin(timeDiff) and @timeDiffLessThanMax(timeDiff)

  processUpdateInterval: (callback=->) =>
    @getFlows =>
      @cleanupFlowStats()
      @restartFailedFlows =>
        @postTriggers callback

  messageFromFlow: (flowId) =>
    flowInfo = @stats.flows[flowId] ?= {}
    flowInfo.messageTime ?= []
    flowInfo.messageTime.unshift @Date.now()
    flowInfo.messageTime = flowInfo.messageTime.slice 0, @CANARY_DATA_HISTORY_SIZE
    flowInfo.timeDiffs ?= []
    if flowInfo.messageTime.length > 1
      flowInfo.timeDiffs.unshift flowInfo.messageTime[0] - flowInfo.messageTime[1]
    flowInfo.timeDiffs = flowInfo.timeDiffs.slice 0, @CANARY_DATA_HISTORY_SIZE
    if flowInfo.timeDiffs[0]? and !@passingTimeDiff flowInfo.timeDiffs[0]
      flowInfo.failures ?= []
      flowInfo.failures.unshift
        time: flowInfo.messageTime[1]
        timeDiff: flowInfo.timeDiffs[0]
      flowInfo.failures = flowInfo.failures.slice 0, @CANARY_ERROR_HISTORY_SIZE

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
    @updateStats()
    return @stats

  getPassing: =>
    @updateStats()
    return {passing:true} if @stats.passing
    return @stats

  updateStats: =>
    _.each @stats.flows, (flowInfo) =>
      lastMessage = flowInfo.messageTime?[0] or flowInfo.startTime?[0] or 0
      flowInfo.currentTimeDiff = @Date.now() - lastMessage
      flowInfo.passing = @timeDiffLessThanMax flowInfo.currentTimeDiff
      _.each flowInfo.timeDiffs, (timeDiff) =>
        flowInfo.passing = false if !@passingTimeDiff timeDiff

    @stats.passing = _.keys(@stats.flows).length != 0
    _.each @stats.flows, (flowInfo) =>
      @stats.passing = false if !flowInfo.passing

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
    @updateStats()
    flowStarters = []
    _.each _.keys(@stats.flows), (flowUuid) =>
      flowInfo = @stats.flows[flowUuid]
      if flowInfo.currentTimeDiff > @CANARY_RESTART_FLOWS_MAX_TIME
        debug "restarting failed flow #{flowUuid}"
        flowStarters.push @curryStartFlow flowUuid
    async.series flowStarters, callback

  postTriggers: (callback=->) =>
    debug 'posting triggers'
    async.each @getTriggers(), (trigger, callback) =>
      flowInfo = @stats.flows[trigger.flowId] ?= {}
      triggerInfo = flowInfo.triggerTime ?= {}
      triggerTime = triggerInfo[trigger.triggerId] ?= []
      triggerTime.unshift @Date.now()
      triggerInfo[trigger.triggerId] = triggerTime.slice 0, @CANARY_DATA_HISTORY_SIZE
      @postTriggerService trigger, => callback()
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
          flowInfo = @stats.flows[flowUuid]
          flowInfo.startTime ?= []
          flowInfo.startTime.unshift @Date.now()
          flowInfo.startTime = flowInfo.startTime.slice 0, @CANARY_DATA_HISTORY_SIZE
          callback()
      , 3000

  addError: (url, body, error) =>
    @stats.errors ?= []
    @stats.errors.unshift {url, body, error, time: @Date.now()}
    @stats.errors = @stats.errors.slice 0, @CANARY_ERROR_HISTORY_SIZE

  requestOctobluUrl: (method, path, callback) =>
    url = "#{@OCTOBLU_API_HOST}#{path}"
    @sendRequest {method, url, @jar}, callback

  postTriggerService: (trigger, callback=->) =>
    url = "#{@OCTOBLU_TRIGGER_HOST}/flows/#{trigger.flowId}/triggers/#{trigger.triggerId}"
    @sendRequest {method:'POST', url}, callback

  sendRequest: (options, callback) =>
    debug "#{options?.method} request #{options?.url}"
    request options, (error, response, body) =>
      body = undefined if _.isEmpty body
      urlInfo = "[#{response?.statusCode}] #{options?.method} #{options?.url}"
      debug urlInfo
      if error? or response?.statusCode >= 400
        @addError urlInfo, body, error?.message
        return callback new Error urlInfo
      callback null, body

module.exports = Canary
