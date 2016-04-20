Slack = require './slack'

class SlackMessageController

  constructor: ({@slack,@stats,@CANARY_UPDATE_INTERVAL,@CANARY_HEALTH_CHECK_MAX_DIFF}={}) ->
    @slack ?= new Slack {@stats,@CANARY_UPDATE_INTERVAL,@CANARY_HEALTH_CHECK_MAX_DIFF}

  sendSlackNotifications: (req, res) =>
    @slack.doSlackNotifications(req.body?.callback())

module.exports = SlackMessageController
