shmock = require 'shmock'
SlackMessageController = require '../src/slack/slack-message-controller'

SLACK_HOST_PORT   = 0xf00d

describe 'Slack', ->
  @timeout 30000

  before ->
    process.env.SLACK_CHANNEL_URL = 'http://localhost:' + SLACK_HOST_PORT + '/slackTest'
    @slackHost                    = shmock SLACK_HOST_PORT
    @CANARY_UPDATE_INTERVAL       = process.env.CANARY_UPDATE_INTERVAL       = 1000*120
    @CANARY_HEALTH_CHECK_MAX_DIFF = process.env.CANARY_HEALTH_CHECK_MAX_DIFF = 100

    @sut = new SlackMessageController @CANARY_UPDATE_INTERVAL, @CANARY_HEALTH_CHECK_MAX_DIFF

  after (done) ->
    @slackHost.close done

  describe '-> slack', ->
    it 'should have a sendSlackNotifications function', ->
      expect(@sut.sendSlackNotifications).to.exist

    describe 'when sendSlackNotifications is called with a passing flow', ->
      before ->
        @stats = {
          flows: {
            'fancy-uuid': {
              name: "Collect Test",
              timeDiffs: [
                120000
              ]
            }
          }
        }
        sinon.spy(@sut.slack, 'curryPostSlackNotification')
        @sut.sendSlackNotifications(@stats)

      it 'should call curryPostSlackNotification with passing message', ->
        expect(@sut.slack.curryPostSlackNotification).to.have.been.called
