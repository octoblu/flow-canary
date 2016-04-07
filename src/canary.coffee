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
    @CANARY_HEALTH_CHECK_MAX_DIFF  = Number.parseInt(process.env.CANARY_HEALTH_CHECK_MAX_DIFF)  or 1000*2
    @CANARY_DATA_HISTORY_SIZE      = Number.parseInt(process.env.CANARY_DATA_HISTORY_SIZE)      or 5
    @CANARY_ERROR_HISTORY_SIZE     = Number.parseInt(process.env.CANARY_ERROR_HISTORY_SIZE)     or 20

    @SLACK_CHANNEL_URL = process.env.SLACK_CHANNEL_URL
    throw new Error('SLACK_CHANNEL_URL must be defined') unless @SLACK_CHANNEL_URL

    unless @OCTOBLU_CANARY_UUID and @OCTOBLU_CANARY_TOKEN
      throw new Error 'Canary UUID or token not defined'

    @jar = request.jar()
    @jar.setCookie request.cookie("meshblu_auth_uuid=#{@OCTOBLU_CANARY_UUID}"), @OCTOBLU_API_HOST
    @jar.setCookie request.cookie("meshblu_auth_token=#{@OCTOBLU_CANARY_TOKEN}"), @OCTOBLU_API_HOST
    @stats =
      flows: {}
      startTime: @Date.now()
    @flows = []
    @slackNotifications = {}

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
        @postTriggers =>
          @doSlackNotifications callback

  doSlackNotifications: (callback) =>
    stats = @getCurrentStats()
    notifications = []

    if !@slackNotifications['lastNotify']
      notifications.push @curryPostSlackNotification {
        attachments: [{color:"good",text:"The flow-canary is alive!"}]
      }

    @slackNotifications['lastError'] ?= 0
    stats.errors ?= []
    _.each stats.errors.reverse(), (errorInfo) =>
      if @slackNotifications['lastError'] < errorInfo.time
        @slackNotifications['lastError'] = errorInfo.time
        notifications.push @curryPostSlackNotification {
          icon_emoji: ':bird:'
          username: 'flow-canary-wut'
          attachments: [{color:"warning",text:"Error: #{errorInfo.url}"}]
        }

    _.forIn stats.flows, (flow, flowId) =>
      @slackNotifications[flowId] ?= true

      if !flow.passing and @slackNotifications[flowId]
        debug {flowId, flow}
        @slackNotifications[flowId] = false
        notifications.push @curryPostSlackNotification {
          icon_emoji: ':skull:'
          username: 'flow-canary-ded'
          attachments: [{color:"danger",text:"Flow #{flow.name} (#{flowId}) is failing"}]
        }

      if flow.passing and !@slackNotifications[flowId]
        @slackNotifications[flowId] = true
        notifications.push @curryPostSlackNotification {
          attachments: [{color:"good",text:"Flow #{flow.name} (#{flowId}) is now passing"}]
        }

    lastUpdate = Date.now() - @slackNotifications['lastNotify']
    if !stats.passing and lastUpdate >= 60*60*1000
      notifications.push @curryPostSlackNotification {
        icon_emoji: ':skull:'
        username: 'flow-canary-ded'
        attachments: [{color:"danger",text:"Flow-canary is still failing!"}]
      }

    async.series notifications, callback

  unshiftData: (obj, prop, data, trimSize=@CANARY_DATA_HISTORY_SIZE) =>
    obj[prop] ?= []
    obj[prop].unshift data
    obj[prop] = obj[prop].slice 0, trimSize

  messageFromFlow: (flowId) =>
    flowInfo = @stats.flows[flowId] ?= {}
    @unshiftData flowInfo, 'messageTime', @Date.now()
    return if flowInfo.messageTime.length < 2
    @unshiftData flowInfo, 'timeDiffs', flowInfo.messageTime[0] - flowInfo.messageTime[1]
    return if @passingTimeDiff flowInfo.timeDiffs[0]
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
      @unshiftData triggerInfo, trigger.triggerId, @Date.now()
      @postTriggerService trigger, => callback()
    , callback

  curryPostSlackNotification: (payload)=>
    defaultPayload =
      username: 'flow-canary'
      icon_emoji: ':baby_chick:'

    options =
      uri: @SLACK_CHANNEL_URL
      method: 'POST'
      body: _.merge defaultPayload, payload
      json: true

    @slackNotifications['lastNotify'] = Date.now()

    return (callback=->) =>
      debug JSON.stringify options
      request options, (error, response, body) =>
        console.error error if error?
        debug {body}
        callback()

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
          @unshiftData flowInfo, 'startTime', @Date.now()
          callback()
      , 3000

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
        @unshiftData @stats, 'errors',
          url: urlInfo
          body: body
          error: error?.message
          time: @Date.now()
        , @CANARY_ERROR_HISTORY_SIZE
        return callback new Error urlInfo
      callback null, body

module.exports = Canary
