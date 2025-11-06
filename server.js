const express = require('express');
const cors = require('cors');
const os = require('os');

const app = express();
app.use(express.json());
app.use(cors());

app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', host: os.hostname(), timestamp: Date.now() });
});

app.get('/api/hello', (req, res) => {
  res.json({ message: 'Hello from backend!', host: os.hostname() });
});

const PORT = process.env.PORT || 4000;
app.listen(PORT, () => {
  console.log(`Backend listening on port ${PORT}`);
});
