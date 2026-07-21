'use strict'

const crypto = require('crypto')
const fs = require('fs')
const bcrypt = require('/edgev3/webapp/server/node_modules/bcryptjs')
const mongoose = require('/edgev3/webapp/server/node_modules/mongoose')

const ADMIN_EMAIL = 'admin@my.edge'
const MAX_CONNECT_ATTEMPTS = 30
const RETRY_DELAY_MS = 2000

const readSecret = path => {
  const value = fs.readFileSync(path, 'utf8').trim()
  if (!value) {
    throw new Error(`Required secret is empty: ${path}`)
  }
  return value
}

const sleep = milliseconds =>
  new Promise(resolve => setTimeout(resolve, milliseconds))

const connectToMongo = async uri => {
  for (let attempt = 1; attempt <= MAX_CONNECT_ATTEMPTS; attempt += 1) {
    try {
      await mongoose.connect(uri, { serverSelectionTimeoutMS: 5000 })
      return
    } catch (_error) {
      await mongoose.disconnect().catch(() => {})
      if (attempt === MAX_CONNECT_ATTEMPTS) {
        throw new Error('MongoDB was not ready before the retry limit')
      }
      console.log(
        `MongoDB is not ready for web-admin initialization (attempt ${attempt}/${MAX_CONNECT_ATTEMPTS}); retrying...`,
      )
      await sleep(RETRY_DELAY_MS)
    }
  }
}

const initializeAdmin = async () => {
  const mongoUser = readSecret('/run/secrets/mongo_app_user')
  const mongoPassword = readSecret('/run/secrets/mongo_app_pass')
  const adminPassword = readSecret('/run/secrets/edgev3_admin_password')
  const adminCode = readSecret('/run/secrets/edgev3_admin_code')

  if (!/^\d{6}$/.test(adminCode)) {
    throw new Error('EDGEv3 administrator code must contain exactly six digits')
  }

  const credentialId = crypto
    .createHash('sha256')
    .update(adminPassword)
    .update('\0')
    .update(adminCode)
    .digest('hex')
  const mongoUri = `mongodb://${encodeURIComponent(mongoUser)}:${encodeURIComponent(
    mongoPassword,
  )}@mongodb:27017/edgev3?authSource=admin`

  await connectToMongo(mongoUri)

  const users = mongoose.connection.db.collection('users')
  const existingAdmin = await users.findOne({ email: ADMIN_EMAIL })
  if (existingAdmin?.bootstrapCredentialId === credentialId) {
    console.log('EDGEv3 web administrator is already initialized')
    return
  }

  const now = new Date()
  const passwordHash = await bcrypt.hash(adminPassword, 10)
  await users.updateOne(
    { email: ADMIN_EMAIL },
    {
      $set: {
        role: 'admin',
        firstName: 'admin',
        lastName: 'edge',
        email: ADMIN_EMAIL,
        active: true,
        password: passwordHash,
        code: adminCode,
        notification: { email: ADMIN_EMAIL, isOn: false },
        job: { limit: 100, priority: 0 },
        bootstrapCredentialId: credentialId,
        updated: now,
      },
      $setOnInsert: { created: now },
      $unset: { firstname: '', lastname: '' },
    },
    { upsert: true },
  )

  console.log('EDGEv3 web administrator initialized from runtime secrets')
}

initializeAdmin()
  .catch(() => {
    console.error('FATAL: EDGEv3 web administrator initialization failed')
    process.exitCode = 1
  })
  .finally(async () => {
    await mongoose.disconnect().catch(() => {})
  })
