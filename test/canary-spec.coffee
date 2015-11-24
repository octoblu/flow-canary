shmock = require 'shmock'
Canary = require '../src/canary'

describe 'Canary', ->
  beforeEach ->
    @meshblu = shmock 0xd00d

  afterEach (done) ->
    @meshblu.close => done()

  describe '-> canary', ->
    beforeEach ->
      meshbluConfig = server: 'localhost', port: 0xd00d
      @sut = new Canary {meshbluConfig}

    it 'should have a message function', ->
      expect(@sut.message).to.exist

    it 'should have a status function', ->
      expect(@sut.status).to.exist
