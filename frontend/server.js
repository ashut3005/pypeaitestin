const express = require('express');  // Web server framework
const path = require('path');        // File path handling

const app = express();
const PORT = process.env.PORT || 3000;  // Listen on port 3000

// Serve static files (CSS, JS, images from frontend folder)
app.use(express.static(path.join(__dirname)));

// HEALTH CHECK ENDPOINT - Required for deployment script
// Script pings this every 2 seconds to verify app is running
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'healthy' });
});

// Serve index.html when user visits root URL
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'index.html'));
});

// Start server
app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
