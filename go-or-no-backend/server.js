require('dotenv').config();
const express = require('express');
const OpenAI = require('openai');

const app = express();
const port = process.env.PORT || 3000;

// Ensure OPENAI_API_KEY is set
if (!process.env.OPENAI_API_KEY) {
    console.error('FATAL ERROR: OPENAI_API_KEY is not set in the environment variables.');
    process.exit(1); // Exit if the key is missing
}

const openai = new OpenAI({
    apiKey: process.env.OPENAI_API_KEY,
});

// Middleware to parse JSON bodies (with increased limit for image data)
app.use(express.json({ limit: '10mb' })); 

// Endpoint to handle image description requests
app.post('/describe-image', async (req, res) => {
    const { imageData } = req.body;

    if (!imageData) {
        return res.status(400).json({ error: 'Missing imageData in request body' });
    }

    console.log('Received image description request...');

    try {
        const response = await openai.chat.completions.create({
            model: "gpt-4o",
            messages: [
                {
                    role: "user",
                    content: [
                        { 
                            type: "text", 
                            text: "You are assisting a visually impaired user who is walking. Describe the immediate path ahead concisely (max 2-3 short sentences), focusing ONLY on safety and navigation. Identify the most important obstacle or navigation feature (e.g., 'Wall 1 meter ahead', 'Clear path', 'Stairs descending', 'Crosswalk ahead'). Mention secondary relevant features briefly if necessary for context (e.g., 'Person approaching on the left', 'Doorway on the right'). Omit cosmetic details like colors and materials."
                        },
                        {
                            type: "image_url",
                            image_url: {
                                // Prepend the necessary prefix for base64 data URI
                                "url": `data:image/jpeg;base64,${imageData}`,
                            },
                        },
                    ],
                },
            ],
            max_tokens: 100, // Limit the length of the description
        });

        console.log('OpenAI response received.');

        // Extract the description text
        const description = response.choices[0]?.message?.content || "Could not get description from AI.";
        
        // Send the description back to the client
        res.json({ description });

    } catch (error) {
        console.error('Error calling OpenAI:', error);
        res.status(500).json({ error: 'Failed to get description from AI' });
    }
});

// Simple route for testing server is running
app.get('/', (req, res) => {
    res.send('Go or No Backend is running!');
});

app.listen(port, () => {
    console.log(`Backend server listening on port ${port}`);
}); 