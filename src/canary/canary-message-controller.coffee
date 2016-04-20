Canary = require './canary'

class CanaryMessageController

  constructor: ({@canary,Date}={}) ->
    @canary ?= new Canary {Date}

  postMessage: (req, res) =>
    res.end()
    @canary.messageFromFlow req.body?.fromUuid

  getPassing: (req, res) =>
    res.json(@canary.getPassing()).end()

  getStats: (req, res) =>
    res.json(@canary.getStats()).end()

module.exports = CanaryMessageController
