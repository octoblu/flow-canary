shmock = require 'shmock'
CanaryMessageController = require '../src/canary-message-controller'
_ = require 'lodash'

API_HOST_PORT     = 0xdead
TRIGGER_HOST_PORT = 0xbeef

describe 'Canary', ->
  @timeout 30000

  before ->
    process.env.OCTOBLU_CANARY_UUID  = 'canary_uuid'
    process.env.OCTOBLU_CANARY_TOKEN = 'canary_token'
    process.env.OCTOBLU_API_HOST     = 'http://localhost:' + API_HOST_PORT
    process.env.OCTOBLU_TRIGGER_HOST = 'http://localhost:' + TRIGGER_HOST_PORT

    # process.env.CANARY_STATS_CLEANUP_INTERVAL = 1
    # process.env.CANARY_RESTART_FLOWS_INTERVAL = 1
    # process.env.CANARY_RESTART_FLOWS_MAX_TIME = 1
    # process.env.CANARY_POST_TRIGGERS_INTERVAL = 1
    # process.env.CANARY_HEALTH_CHECK_MAX_TIME  = 1
    # process.env.CANARY_HISTORY_SIZE           = 1

    @apiHost     = shmock API_HOST_PORT
    @triggerHost = shmock TRIGGER_HOST_PORT

    @flows = [
        flowId: "flow-a"
        activated: true
        nodes: [
            id: "trigger-flow-a"
            type: "operation:trigger"
        ]
      ,
        flowId: "flow-b"
        nodes: [
            id: "trigger-flow-b"
            type: "operation:trigger"
        ]
      ,
        flowId: "flow-c"
    ]

    @sut = new CanaryMessageController

    @resetFlowTime = (name, time) =>
      @sut.canary.stats.flows[name] = {messageTime:[time]}

  after (done) ->
    @apiHost.close =>
      @triggerHost.close done

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
      expect(@sut.canary.getCurrentStats).to.exist

    it 'should have an initial failing state', ->
      expect(@sut.canary.getPassing().passing).to.equal false

    describe 'when startAllFlows is called', ->
      before (done) ->
        @getFlows = @apiHost.get('/api/flows').reply(200, @flows)
        @startFlowA = @apiHost.post('/api/flows/flow-a/instance').reply(201)
        @startFlowB = @apiHost.post('/api/flows/flow-b/instance').reply(201)
        @startFlowC = @apiHost.post('/api/flows/flow-c/instance').reply(201)
        @sut.canary.startAllFlows done

      it 'should have fetched our flows and started them', ->
        expect(@getFlows.isDone).to.be.true
        expect(@startFlowA.isDone).to.be.true
        expect(@startFlowB.isDone).to.be.true
        expect(@startFlowC.isDone).to.be.true

      it 'should be in a passing state', ->
        expect(@sut.canary.getPassing().passing).to.equal true

    describe 'when one of the flows hasn\'t been messaged in awhile', ->
      before ->
        @resetFlowTime 'flow-a', 0

      it 'should be in a failing state', ->
        expect(@sut.canary.getPassing().passing).to.equal false

      describe 'and we message it a bunch', ->
        before ->
          messageCanary = =>
            @sut.postMessage {body:fromUuid:'flow-a'}, {end:=>}
          _.times 20, messageCanary

        it 'should be in a passing state', ->
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
        @resetFlowTime 'flow-c', 0

      it 'should be in a failing state', ->
        expect(@sut.canary.getPassing().passing).to.equal false

      describe 'when processUpdateInterval is called', ->
        before (done) ->
          @getFlows = @apiHost.get('/api/flows').reply(200, @flows)
          @startFlowC = @apiHost.post('/api/flows/flow-c/instance').reply(201)
          @triggerAPost = @triggerHost.post('/flows/flow-a/triggers/trigger-flow-a').reply(201)
          @triggerBPost = @triggerHost.post('/flows/flow-b/triggers/trigger-flow-b').reply(201)
          @sut.canary.processUpdateInterval done

        it 'should have fetched the flows, restarted the failed flow, and posted to triggers', ->
          expect(@getFlows.isDone).to.be.true
          expect(@startFlowC.isDone).to.be.true
          expect(@triggerAPost.isDone).to.be.true
          expect(@triggerBPost.isDone).to.be.true

        it 'should have no errors in stats', ->
          expect(@sut.canary.getCurrentStats().errors).to.not.exist

    describe 'when processUpdateInterval and everything errors', ->
      before (done) ->
        @resetFlowTime 'flow-c', 0
        @getFlows = @apiHost.get('/api/flows').reply(401, @flows)
        @startFlowC = @apiHost.post('/api/flows/flow-c/instance').reply(401)
        @triggerAPost = @triggerHost.post('/flows/flow-a/triggers/trigger-flow-a').reply(401)
        @triggerBPost = @triggerHost.post('/flows/flow-b/triggers/trigger-flow-b').reply(401)
        @sut.canary.processUpdateInterval done

      it 'should have tried to fetch the flows, restart the failed flow, and post to triggers', ->
        expect(@getFlows.isDone).to.be.true
        expect(@startFlowC.isDone).to.be.true
        expect(@triggerAPost.isDone).to.be.true
        expect(@triggerBPost.isDone).to.be.true

      it 'should have errors in stats', ->
        expect(@sut.canary.getCurrentStats().errors?.length).to.equal 4
