module.exports = {
  apps: [
    {
      name: 'hello',
      script: process.env.HOME + '/host/services/hello/server.js',
      instances: 1,
      autorestart: true,
      watch: false,
      max_memory_restart: '256M',
    },
  ],
};