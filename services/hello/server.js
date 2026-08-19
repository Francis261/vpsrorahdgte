const http = require('http');

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('vps-relay hello\n');
});

server.listen(8080, '0.0.0.0', () => {
  console.log('hello listening on :8080');
});
