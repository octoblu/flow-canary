_ = require 'lodash'
debug = (require 'debug')('octoblu-flow-canary:stats')

class Stats

  constructor: ({@Date,@stats,@CANARY_UPDATE_INTERVAL,@CANARY_HEALTH_CHECK_MAX_DIFF} = {}) ->
    @Date ?= Date
    @stats ?=
      flows: {}
      startTime: @Date.now()

  setCanaryErrors: (error, trimSize) =>
    @stats.errors ?= []
    @stats.errors.unshift error
    @stats.errors = @stats.errors.slice 0, trimSize

  setFlowNames: (flow) =>
    @stats.flows[flow.flowId] ?= {}
    @stats.flows[flow.flowId].name = flow.name

  getFlowById: (flowId) =>
    @stats.flows[flowId] ?= {}
    return @stats.flows[flowId]

  getFlows: =>
    return @stats.flows

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

  cleanupFlowStats: (flows) =>
    debug 'cleaning up flow stats'
    flowIds = {}
    _.each flows, (flow) =>
      debug "has flow id #{flow.flowId}"
      flowIds[flow.flowId] = true
    _.each _.keys(@stats.flows), (flowUuid) =>
      if !flowIds[flowUuid]
        delete @stats.flows[flowUuid]

  timeDiffGreaterThanMin: (timeDiff) =>
    return timeDiff >= (@CANARY_UPDATE_INTERVAL - @CANARY_HEALTH_CHECK_MAX_DIFF)

  timeDiffLessThanMax: (timeDiff) =>
    return timeDiff <= (@CANARY_UPDATE_INTERVAL + @CANARY_HEALTH_CHECK_MAX_DIFF)

  passingTimeDiff: (timeDiff) =>
    return @timeDiffGreaterThanMin(timeDiff) and @timeDiffLessThanMax(timeDiff)

module.exports = Stats
