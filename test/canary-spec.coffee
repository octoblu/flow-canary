_ = require 'lodash'
shmock = require 'shmock'
MessageController = require '../src/message-controller'

API_HOST_PORT     = 0xdead
TRIGGER_HOST_PORT = 0xbeef
SLACK_HOST_PORT   = 0xf00d

describe 'Canary', ->
  @timeout 30000

  before ->
    @DateMock =
      now: => @time or 0
      setTime: (@time) =>
      inc: (delta) => @time += delta

    @startTime = Date.now()
    @DateMock.setTime @startTime

    process.env.OCTOBLU_CANARY_UUID  = 'canary_uuid'
    process.env.OCTOBLU_CANARY_TOKEN = 'canary_token'
    process.env.OCTOBLU_API_HOST     = 'http://localhost:' + API_HOST_PORT
    process.env.OCTOBLU_TRIGGER_HOST = 'http://localhost:' + TRIGGER_HOST_PORT
    process.env.SLACK_CHANNEL_URL    = 'http://localhost:' + SLACK_HOST_PORT + '/slackTest'

    @CANARY_RESTART_FLOWS_MAX_TIME = process.env.CANARY_RESTART_FLOWS_MAX_TIME = 1000*60
    @CANARY_UPDATE_INTERVAL        = process.env.CANARY_UPDATE_INTERVAL        = 1000*120
    @CANARY_HEALTH_CHECK_MAX_DIFF  = process.env.CANARY_HEALTH_CHECK_MAX_DIFF  = 100
    @CANARY_DATA_HISTORY_SIZE      = process.env.CANARY_DATA_HISTORY_SIZE      = 3

    @apiHost     = shmock API_HOST_PORT
    @triggerHost = shmock TRIGGER_HOST_PORT
    @slackHost   = shmock SLACK_HOST_PORT

    @flows = [
        flowId: "flow-a"
        name: "trigger flow a"
        activated: true
        nodes: [
            id: "trigger-flow-a"
            type: "operation:trigger"
        ]
      ,
        flowId: "flow-b"
        name: "trigger flow b"
        nodes: [
            id: "trigger-flow-b"
            type: "operation:trigger"
        ]
      ,
        flowId: "flow-c"
        name: "something something"
    ]

    @sut = new MessageController Date: @DateMock

    @resetFlowTime = (name, time) =>
      (@sut.canary.stats.getFlows())[name] = {messageTime:[time]}

  after (done) ->
    @apiHost.close =>
      @triggerHost.close =>
        @slackHost.close done

  describe '-> canary', ->
    it 'should have a message endpoint', ->
      expect(@sut.postMessage).to.exist

    it 'should have a stats endpoint', ->
      expect(@sut.getStats).to.exist

    it 'should have a passing endpoint', ->
      expect(@sut.getPassing).to.exist

    it 'should have a postTriggers function', ->
      expect(@sut.canary.postTriggers).to.exist

    it 'should have a function for getting current stats', ->
      expect(@sut.canary.getStats).to.exist

    it 'should have an initial failing state', ->
      expect(@sut.canary.getPassing().passing).to.equal false

    describe 'when startAllFlows is called', ->
      before (done) ->
        @getFlows = @apiHost.get('/api/flows').reply(200, @flows)
        @startFlowA = @apiHost.post('/api/flows/flow-a/instance').reply(201)
        @startFlowB = @apiHost.post('/api/flows/flow-b/instance').reply(201)
        @startFlowC = @apiHost.post('/api/flows/flow-c/instance').reply(201)
        @sut.canary.startAllFlows =>
          @DateMock.inc @CANARY_UPDATE_INTERVAL
          done()

      it 'should have fetched our flows and started them', ->
        expect(@getFlows.isDone).to.be.true
        expect(@startFlowA.isDone).to.be.true
        expect(@startFlowB.isDone).to.be.true
        expect(@startFlowC.isDone).to.be.true

      it 'should be in a passing state', ->
        expect(@sut.canary.getPassing().passing).to.equal true

      describe 'when one of the flows hasn\'t been messaged in awhile', ->
        before ->
          @resetFlowTime 'flow-a', @DateMock.now() - @CANARY_UPDATE_INTERVAL*2

        it 'should be in a failing state', ->
          expect(@sut.canary.getPassing().passing).to.equal false

        describe 'and we message them a bunch', ->
          before ->
            messageCanary = =>
              @DateMock.inc @CANARY_UPDATE_INTERVAL
              @sut.postMessage {body:fromUuid:'flow-a'}, {end:=>}
              @sut.postMessage {body:fromUuid:'flow-b'}, {end:=>}
              @sut.postMessage {body:fromUuid:'flow-c'}, {end:=>}
            _.times @CANARY_DATA_HISTORY_SIZE+1, messageCanary

          it 'should be in a passing state', ->
            # console.log JSON.stringify @sut.canary.getCurrentStats(), null, 2
            expect(@sut.canary.getPassing().passing).to.equal true

          describe 'when postTriggers is called', ->
            before (done) ->
              @triggerAPost = @triggerHost.post('/flows/flow-a/triggers/trigger-flow-a').reply(201)
              @triggerBPost = @triggerHost.post('/flows/flow-b/triggers/trigger-flow-b').reply(201)
              @sut.canary.postTriggers done

            it 'should have posted to both triggers', ->
              expect(@triggerAPost.isDone).to.be.true
              expect(@triggerBPost.isDone).to.be.true

            describe 'when one of the other flows hasn\'t been messaged in awhile', ->
              before ->
                @resetFlowTime 'flow-c', @DateMock.now() - @CANARY_UPDATE_INTERVAL*2

              it 'should be in a failing state', ->
                # console.log JSON.stringify @sut.canary.getCurrentStats(), null, 2
                expect(@sut.canary.getPassing().passing).to.equal false

              describe 'when processUpdateInterval is called', ->
                before (done) ->
                  @getFlows = @apiHost.get('/api/flows').reply(200, @flows)
                  @startFlowC = @apiHost.post('/api/flows/flow-c/instance').reply(201)
                  @triggerAPost = @triggerHost.post('/flows/flow-a/triggers/trigger-flow-a').reply(201)
                  @triggerBPost = @triggerHost.post('/flows/flow-b/triggers/trigger-flow-b').reply(201)
                  @slackPost = @slackHost.post('/slackTest').reply(200)

                  @sut.canary.processUpdateInterval done

                it 'should have fetched the flows, restarted the failed flow, and posted to triggers', ->
                  expect(@getFlows.isDone).to.be.true
                  expect(@startFlowC.isDone).to.be.true
                  expect(@triggerAPost.isDone).to.be.true
                  expect(@triggerBPost.isDone).to.be.true
                  expect(@slackPost.isDone).to.be.true

                it 'should have no errors in stats', ->
                  # console.log JSON.stringify @sut.canary.getCurrentStats(), null, 2
                  expect(_.isEmpty(@sut.canary.getStats().errors)).to.be.true

            describe 'when processUpdateInterval and everything errors', ->
              before (done) ->
                @resetFlowTime 'flow-c', @DateMock.now() - @CANARY_UPDATE_INTERVAL*2
                @getFlows = @apiHost.get('/api/flows').reply(401, @flows)
                @startFlowC = @apiHost.post('/api/flows/flow-c/instance').reply(401)
                @triggerAPost = @triggerHost.post('/flows/flow-a/triggers/trigger-flow-a').reply(401)
                @triggerBPost = @triggerHost.post('/flows/flow-b/triggers/trigger-flow-b').reply(401)
                @slackPost = @slackHost.post('/slackTest').reply(200)

                @sut.canary.processUpdateInterval done

              it 'should have tried to fetch the flows, restart the failed flow, and post to triggers', ->
                expect(@getFlows.isDone).to.be.true
                expect(@startFlowC.isDone).to.be.true
                expect(@triggerAPost.isDone).to.be.true
                expect(@triggerBPost.isDone).to.be.true
                expect(@slackPost.isDone).to.be.true

              it 'should have errors in stats', ->
                # console.log JSON.stringify @sut.canary.getCurrentStats(), null, 2
                expect(@sut.canary.getStats().errors?.length).to.equal 4

            describe 'when one of the flows is messaged too often', ->
              before ->
                @resetFlowTime 'flow-a', @DateMock.now()
                @resetFlowTime 'flow-b', @DateMock.now()
                @resetFlowTime 'flow-c', @DateMock.now()
                delete @sut.canary.stats.errors

              it 'should initialy be in a passing state', ->
                expect(@sut.canary.getPassing().passing).to.equal true

              describe 'and we message a flow once', ->
                before ->
                  @DateMock.inc @CANARY_UPDATE_INTERVAL - (@CANARY_HEALTH_CHECK_MAX_DIFF*1.1)
                  @sut.postMessage {body:fromUuid:'flow-a'}, {end:=>}

                it 'should be in a failing state', ->
                  # console.log JSON.stringify @sut.canary.getCurrentStats(), null, 2
                  expect(@sut.canary.getPassing().passing).to.equal false
