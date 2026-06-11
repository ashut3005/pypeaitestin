// const express = require('express'); 
// const path = require('path');       

// const app = express();
// const PORT = process.env.PORT || 3000;  

// app.use(express.static(path.join(__dirname)));

// app.get('/health', (req, res) => {
//   res.status(200).json({ status: 'healthy' });
// });


// app.get('/', (req, res) => {
//   res.sendFile(path.join(__dirname, 'index.html'));
// });


// app.listen(PORT, () => {
//   console.log(`Server running on port ${PORT}`);
// });


const express = require('express');
const path = require('path');
const fs = require('fs');

const app = express();
const PORT = process.env.PORT || 3000;

// Create logs directory if it doesn't exist
const logsDir = path.join(__dirname, 'logs');
if (!fs.existsSync(logsDir)) {
    fs.mkdirSync(logsDir);
}

const logFile = path.join(logsDir, 'app.log');

// Custom logging middleware
app.use((req, res, next) => {
    const timestamp = new Date().toISOString();
    const logMessage = `${timestamp} | ${req.method} ${req.url} | IP: ${req.ip}\n`;

    // Write to file
    fs.appendFile(logFile, logMessage, (err) => {
        if (err) {
            console.error('Failed to write log:', err);
        }
    });

    // Write to container stdout
    console.log(logMessage.trim());

    next();
});

app.use(express.static(path.join(__dirname)));

app.get('/health', (req, res) => {
    console.log('Health check endpoint called');
    res.status(200).json({ status: 'healthy' });
});

app.get('/', (req, res) => {
    console.log('Home page requested');
    res.sendFile(path.join(__dirname, 'index.html'));
});

// Handle errors
app.use((err, req, res, next) => {
    console.error('Application Error:', err);
    res.status(500).json({ error: 'Internal Server Error' });
});

app.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
});
