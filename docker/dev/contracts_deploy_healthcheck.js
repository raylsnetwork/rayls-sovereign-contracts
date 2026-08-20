const http = require('http');
const fs = require('fs');

// Create an HTTP server
const server = http.createServer((req, res) => {
    // Check if the request is for the root URL
    if (req.url === '/') {
        fs.readFile('/tmp/deploy_status', 'utf8', function (err, data) {
            let progress = 0.0;
            let details = '';

            if (!err) {
                const parts = data.split(',');
                if (parts.length > 0) {
                    // Extract progress value
                    const progressStr = parts[0];
                    const parsedProgress = parseFloat(progressStr);
                    progress = isNaN(parsedProgress) ? 0.0 : parsedProgress;

                    // Extract description
                    if (parts.length > 1) {
                        details = parts.slice(1).join(',').trim();
                    }
                }
            }

            if (progress >= 1.0) {
                res.writeHead(200, { 'Content-Type': 'application/json' });
                const response = JSON.stringify({ status: 'deployed', progress: progress, details });
                res.end(response);
            } else {
                res.writeHead(503, { 'Content-Type': 'application/json' });
                const response = JSON.stringify({ status: 'deploying', progress: progress, details });
                res.end(response);
            }
        });
    } else {
        // For any other URL, return a 404 status code
        res.writeHead(404, { 'Content-Type': 'text/plain' });
        res.end('Not Found\n');
    }
});

// Function to gracefully shut down the server
function shutDownServer() {
    console.log('Received signal to terminate, closing HTTP server...');

    // Close the server and prevent new connections
    server.close((err) => {
        if (err) {
            console.error('Error shutting down server:', err);
        }
        console.log('Server has been shut down');
        process.exit(err ? 1 : 0); // Exit with non-zero code if there was an error
    });
}

// Listen for termination signals
process.on('SIGINT', () => {
    console.log('SIGINT signal received: closing server...');
    shutDownServer();
});

process.on('SIGTERM', () => {
    console.log('SIGTERM signal received: closing server...');
    shutDownServer();
});

// Listen on port 7000
server.listen(7000, () => {
    console.log('Deployment healthcheck running...');
});
