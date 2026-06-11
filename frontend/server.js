const express = require('express');
const path = require('node:path');
const fs = require('node:fs');

const app = express();
const PORT = process.env.PORT || 3000;

// Create logs directory if it doesn't exist
const logsDir = path.join(__dirname, 'logs');
fs.mkdirSync(logsDir, { recursive: true });

const logFile = path.join(logsDir, 'app.log');

// Custom logging middleware
app.use((req, res, next) => {
    const timestamp = new Date().toISOString();
    const logMessage = `${timestamp} | ${req.method} ${req.url} | IP: ${req.ip}\n`;

    // Write to log file
    fs.appendFile(logFile, logMessage, (err) => {
        if (err) {
            console.error('Failed to write log:', err);
        }
    });

    // Write to container stdout
    console.log(logMessage.trim());

    next();
});

// Serve static files
app.use(express.static(__dirname));

// Health check endpoint
app.get('/health', (req, res) => {
    console.log('Health check endpoint called');
    res.status(200).json({
        status: 'healthy'
    });
});

// Home page
app.get('/', (req, res) => {
    console.log('Home page requested');
    res.sendFile(path.join(__dirname, 'index.html'));
});

// Error handling middleware
app.use((err, req, res, next) => {
    console.error('Application Error:', err);

    res.status(500).json({
        error: 'Internal Server Error'
    });
});

// Start server
app.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
});