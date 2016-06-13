_ = require 'lodash'
async = require 'async'
request = require 'request'
debug = (require 'debug')('octoblu-flow-canary:slack')

class Slack

  constructor: ({@CANARY_UPDATE_INTERVAL,@CANARY_HEALTH_CHECK_MAX_DIFF}={}) ->
    @slackNotifications = {}

    @SLACK_CHANNEL_URL = process.env.SLACK_CHANNEL_URL
    @SLACK_EMERGENCY_CHANNEL = process.env.SLACK_EMERGENCY_CHANNEL
    @SLACK_EMERGENCY_CHANNEL ?= "#performance-problems"
    throw new Error('SLACK_CHANNEL_URL must be defined') unless @SLACK_CHANNEL_URL
    @startTime = Date.now()

  sendSlackNotifications: (stats, callback) =>
    notifications = []
    update = false
    ded = false

    if !@slackNotifications['lastNotify']
      lowerResponseTime = (@CANARY_UPDATE_INTERVAL - @CANARY_HEALTH_CHECK_MAX_DIFF) / 1000
      upperResponseTime = (@CANARY_UPDATE_INTERVAL + @CANARY_HEALTH_CHECK_MAX_DIFF) / 1000
      notifications.push @curryPostSlackNotification {
        attachments: [{color:"good",text:"The flow-canary is alive! Expected response time is between #{lowerResponseTime} and #{upperResponseTime} seconds"}]
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

      @slackNotifications['lastFailure'] ?= 0
      flow.failures ?= []
      _.each flow.failures.reverse(), (errorInfo) =>
        if @slackNotifications['lastFailure'] < errorInfo.time
          update = true
          ded = true
          @slackNotifications['lastFailure'] = errorInfo.time
          @slackNotifications[flowId] = false
          timeDiffInSeconds = errorInfo.timeDiff / 1000
          notifications.push @curryPostSlackNotification {
            icon_emoji: ':skull:'
            username: 'flow-canary-ded'
            attachments: [
              {
                color:"danger",
                text:"Flow #{flow.name} (#{flowId}) failed because it took #{timeDiffInSeconds} seconds to respond"
              }
            ]
          }

      if flow.passing and !@slackNotifications[flowId]
        @slackNotifications[flowId] = true
        update = true
        notifications.push @curryPostSlackNotification {
          attachments: [{color:"good",text:"Flow #{flow.name} (#{flowId}) is now passing"}]
        }

    if update
      failingFlows = ""
      failCount = 0
      _.each stats.flows, (flowInfo) =>
        if !flowInfo.passing
          failingFlows += ">#{flowInfo.name}< "
          failCount += 1
      if failCount == 0
        notifications.push @curryPostSlackNotification {
          attachments: [{color:"good",text: "All flows are now passing"}]
        }
      if failCount == stats.flows?.length && (Date.now()-@startTime) > 5*60*1000
        notifications.push @curryPostSlackNotification {
          icon_emoji: ':skull:'
          username: 'flow-canary-ded'
          attachments: [{color:"danger",text: "All flows are failing!"}]
        }, true
      else if ded
        notifications.push @curryPostSlackNotification {
          icon_emoji: ':skull:'
          username: 'flow-canary-ded'
          attachments: [{color:"danger",text:"#{failCount} flows are failing: #{failingFlows}"}]
        }
      else
        notifications.push @curryPostSlackNotification {
          attachments: [{color:"danger",text:"#{failCount} flows are failing: #{failingFlows}"}]
        }

    lastUpdate = Date.now() - @slackNotifications['lastNotify']
    if !stats.passing and lastUpdate >= 60*60*1000
      notifications.push @curryPostSlackNotification {
        icon_emoji: ':skull:'
        username: 'flow-canary-ded'
        attachments: [{color:"danger",text:"Flow-canary is still dead!"}]
      }

    async.series notifications, callback

  curryPostSlackNotification: (payload, emergency)=>
    defaultPayload =
      username: 'flow-canary'
      icon_emoji: ':baby_chick:'

    channel = @SLACK_EMERGENCY_CHANNEL if emergency

    options =
      uri: @SLACK_CHANNEL_URL
      channel: channel
      method: 'POST'
      body: _.merge defaultPayload, payload
      json: true

    @slackNotifications['lastNotify'] = Date.now()

    return (callback=->) =>
      debug JSON.stringify options
      request options, (error, response, body) =>
        console.error {error} if error?
        debug {body}
        callback()

module.exports = Slack
