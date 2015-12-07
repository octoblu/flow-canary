Canary = require './canary'

class CanaryMessageController

  constructor: ({@canary,Date}={}) ->
    @canary ?= new Canary {Date}

  getStats: (req, res) =>
    res.json(@canary.getCurrentStats()).end()

  getPassing: (req, res) =>
    res.json(@canary.getPassing()).end()

  postMessage: (req, res) =>
    res.end()
    @canary.messageFromFlow req.body?.fromUuid

module.exports = CanaryMessageController
