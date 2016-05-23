shmock = require 'shmock'
Slack = require '../src/slack'

SLACK_HOST_PORT   = 0x51ac

describe 'Slack', ->
  @timeout 30000

  before ->
    process.env.SLACK_CHANNEL_URL = 'http://localhost:' + SLACK_HOST_PORT + '/slackTest'
    @slackHost                    = shmock SLACK_HOST_PORT
    @CANARY_UPDATE_INTERVAL       = process.env.CANARY_UPDATE_INTERVAL       = 1000*120
    @CANARY_HEALTH_CHECK_MAX_DIFF = process.env.CANARY_HEALTH_CHECK_MAX_DIFF = 100

    @sut = new Slack @CANARY_UPDATE_INTERVAL, @CANARY_HEALTH_CHECK_MAX_DIFF

  after (done) ->
    @slackHost.close done

  describe '-> slack', ->
    it 'should have a sendSlackNotifications function', ->
      expect(@sut.sendSlackNotifications).to.exist

    describe 'when sendSlackNotifications is called with a passing flow', ->
      before (done) ->
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
        sinon.spy(@sut, 'curryPostSlackNotification')
        @sut.sendSlackNotifications @stats, done
        @slackPost = @slackHost.post('/slackTest').reply(200)

      it 'should call curryPostSlackNotification with passing message', ->
        expect(@slackPost.isDone).to.be.true
