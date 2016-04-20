Stats = require './stats'

class StatsMessageController

  constructor: ({@Date,@stats,@CANARY_UPDATE_INTERVAL,@CANARY_HEALTH_CHECK_MAX_DIFF} = {}) ->
    @stats ?= new Stats {@Date,@stats,@CANARY_UPDATE_INTERVAL,@CANARY_HEALTH_CHECK_MAX_DIFF}

  getCurrentStats: (req, res) =>
    @stats.getCurrentStats()

  getPassing: (req, res) =>
    @stats.getPassing()

  getFlows: (req, res) =>
    @stats.getFlows()

  getFlowById: (req, res) =>
    @stats.getFlowById(req)

  cleanupFlowStats: (req, res) =>
    @stats.cleanupFlowStats(req)

  passingTimeDiff: (req, res) =>
    @stats.passingTimeDiff(req)

  updateStats: (req, res) =>
    @stats.updateStats()

  setCanaryErrors: (req, res) =>
    @stats.setCanaryErrors(req)

  setFlowNames: (req, res) =>
    @stats.setFlowNames(req)

module.exports = StatsMessageController
