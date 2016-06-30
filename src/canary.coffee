debug   = (require 'debug')('octoblu-flow-canary:canary')
request = require 'request'
async   = require 'async'
uuid    = require 'uuid'
_       = require 'lodash'
Stats   = require './stats'
Slack   = require './slack'

class Canary

  constructor: ({@Date,@stats,@slack}={})->
    @OCTOBLU_CANARY_UUID  = process.env.OCTOBLU_CANARY_UUID
    @OCTOBLU_CANARY_TOKEN = process.env.OCTOBLU_CANARY_TOKEN
    @OCTOBLU_API_HOST     = process.env.OCTOBLU_API_HOST     or 'https://app.octoblu.com'
    @OCTOBLU_TRIGGER_HOST = process.env.OCTOBLU_TRIGGER_HOST or 'https://triggers.octoblu.com'

    @CANARY_RESTART_FLOWS_MAX_TIME = Number.parseInt(process.env.CANARY_RESTART_FLOWS_MAX_TIME) or 1000*60*5
    @CANARY_UPDATE_INTERVAL        = Number.parseInt(process.env.CANARY_UPDATE_INTERVAL)        or 1000*60
    @CANARY_HEALTH_CHECK_MAX_DIFF  = Number.parseInt(process.env.CANARY_HEALTH_CHECK_MAX_DIFF)  or 1000*2
    @CANARY_DATA_HISTORY_SIZE      = Number.parseInt(process.env.CANARY_DATA_HISTORY_SIZE)      or 5
    @CANARY_ERROR_HISTORY_SIZE     = Number.parseInt(process.env.CANARY_ERROR_HISTORY_SIZE)     or 20

    unless @OCTOBLU_CANARY_UUID and @OCTOBLU_CANARY_TOKEN
      throw new Error 'Canary UUID or token not defined'

    @jar = request.jar()
    @jar.setCookie request.cookie("meshblu_auth_uuid=#{@OCTOBLU_CANARY_UUID}"), @OCTOBLU_API_HOST
    @jar.setCookie request.cookie("meshblu_auth_token=#{@OCTOBLU_CANARY_TOKEN}"), @OCTOBLU_API_HOST

    @flows = []
    @Date ?= Date

    @stats ?= new Stats {@flows,@Date,@CANARY_UPDATE_INTERVAL,@CANARY_HEALTH_CHECK_MAX_DIFF}
    @slack ?= new Slack {@CANARY_UPDATE_INTERVAL,@CANARY_HEALTH_CHECK_MAX_DIFF}

    setInterval @processUpdateInterval, @CANARY_UPDATE_INTERVAL

  getStats: =>
    @stats.getCurrentStats()

  getPassing: =>
    @stats.getPassing()

  processUpdateInterval: (callback=->) =>
    @getFlows =>
      @stats.cleanupFlowStats(@flows)
      @stats.updateStats()

      # @restartFailedFlows =>
      @postTriggers =>
        @slack.sendSlackNotifications @stats.getCurrentStats(), callback

  messageFromFlow: (flowId) =>
    flowInfo = @stats.getFlowById(flowId)
    @unshiftData flowInfo, 'messageTime', @Date.now()
    return if flowInfo.messageTime.length < 2
    @unshiftData flowInfo, 'timeDiffs', flowInfo.messageTime[0] - flowInfo.messageTime[1]
    return if @stats.passingTimeDiff flowInfo.timeDiffs[0]
    @unshiftData flowInfo, 'failures',
      time: flowInfo.messageTime[1]
      timeDiff: flowInfo.timeDiffs[0]
    , @CANARY_ERROR_HISTORY_SIZE

  startAllFlows: (callback=->) =>
    @getFlows =>
      flowStarters = []
      _.each @flows, (flow) => flowStarters.push @curryStartFlow(flow.flowId)
      async.series flowStarters, =>
        debug 'all flows started'
        callback()

  getFlows: (callback) =>
    @requestOctobluUrl 'GET', '/api/flows', (error, body) =>
      return callback error if error?
      return callback new Error 'body is undefined' unless body
      @flows = JSON.parse body
      _.each @flows, (flow) =>
        @stats.setFlowNames(flow)
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
    flowStarters = []
    _.each _.keys(@stats.getFlows()), (flowUuid) =>
      flowInfo = @stats.getFlowById(flowUuid)
      if flowInfo.currentTimeDiff > @CANARY_RESTART_FLOWS_MAX_TIME
        debug "restarting failed flow #{flowUuid}"
        flowStarters.push @curryStartFlow flowUuid
    async.series flowStarters, callback

  postTriggers: (callback=->) =>
    debug 'posting triggers'
    async.each @getTriggers(), (trigger, callback) =>
      flowInfo = @stats.getFlowById(trigger.flowId)
      triggerInfo = flowInfo.triggerTime ?= {}
      @unshiftData triggerInfo, trigger.triggerId, @Date.now()
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
          flowInfo = @stats.getFlowById(flowUuid)
          @unshiftData flowInfo, 'startTime', @Date.now()
          callback()
      , 3000

  requestOctobluUrl: (method, path, callback) =>
    url = "#{@OCTOBLU_API_HOST}#{path}"
    headers = deploymentUuid: "flow-canary-#{uuid.v4()}"
    @sendRequest {headers, method, url, @jar}, callback

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
        @stats.setCanaryErrors {
          url: urlInfo
          body: body
          error: error?.message
          time: @Date.now()
        }, @CANARY_ERROR_HISTORY_SIZE
        return callback new Error urlInfo
      callback null, body

  unshiftData: (obj, prop, data, trimSize=@CANARY_DATA_HISTORY_SIZE) =>
    obj[prop] ?= []
    obj[prop].unshift data
    obj[prop] = obj[prop].slice 0, trimSize

module.exports = Canary
