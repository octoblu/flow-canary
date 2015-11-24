class Canary

  constructor: ({@meshbluConfig}={})->

  message: (req, res) =>
    console.log 'headers:', req.headers
    console.log 'params:', req.params
    console.log 'body:', req.body
    res.end()

  status: (req, res) =>
    res.json({goodStatus:true}).end()

module.exports = Canary
