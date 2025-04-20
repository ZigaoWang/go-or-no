require('dotenv').config();
const express = require('express');
const OpenAI = require('openai');
const fs = require('fs'); // File system module
const path = require('path'); // Path module
const os = require('os'); // OS module for temp directory

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
                            text: "You are assisting a visually impaired user. Describe the main objects and any text visible in this image concisely. Focus on identification and function. Omit visual details like color and texture unless essential for identifying the object (e.g., differentiating products). Keep your answer short and concise."
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

// --- NEW Endpoint for Follow-up Questions ---
app.post('/follow-up-analysis', async (req, res) => {
    // Now expects previousDescription as well
    const { imageData, audioData, previousDescription } = req.body; 

    if (!imageData || !audioData || previousDescription === undefined) { // Check for all three
        return res.status(400).json({ error: 'Missing imageData, audioData, or previousDescription in request body' });
    }

    console.log('Received follow-up analysis request...');

    let tempAudioPath = '';
    try {
        // 1. Decode audio and save temporarily
        const audioBuffer = Buffer.from(audioData, 'base64');
        // Create a unique temporary file path (e.g., in /tmp or os.tmpdir())
        // Update expected extension to .wav
        tempAudioPath = path.join(os.tmpdir(), `followup_${Date.now()}.wav`); 
        fs.writeFileSync(tempAudioPath, audioBuffer);
        console.log(`Temporary audio file saved to: ${tempAudioPath}`);

        // 2. Transcribe audio using Whisper
        console.log('Transcribing audio with Whisper...');
        const transcription = await openai.audio.transcriptions.create({
            file: fs.createReadStream(tempAudioPath),
            model: "whisper-1",
        });
        const userQuestion = transcription.text;
        console.log(`Transcription successful: "${userQuestion}"`);

        // 3. Call GPT-4o with image, PREVIOUS DESCRIPTION, and transcribed question
        console.log('Asking follow-up question to GPT-4o with context...');
        const followUpResponse = await openai.chat.completions.create({
            model: "gpt-4o",
            // Provide conversation history including the previous description
            messages: [
                {
                    role: "user", // Initial image prompt context
                    content: [
                        { type: "text", text: "Describe this image for a visually impaired user, focusing on identification, function, and navigation. Omit non-essential details." }, // You might adjust this initial context prompt
                        {
                            type: "image_url",
                            image_url: {
                                "url": `data:image/jpeg;base64,${imageData}`,
                            },
                        },
                    ],
                },
                {
                    role: "assistant", // The AI's previous response
                    content: previousDescription
                },
                {
                    role: "user", // The user's follow-up question
                    content: userQuestion
                }
            ],
            max_tokens: 100, 
        });

        console.log('GPT-4o follow-up response received.');
        const answer = followUpResponse.choices[0]?.message?.content || "Could not get an answer.";

        // 4. Send the answer back
        res.json({ answer });

    } catch (error) {
        console.error('Error during follow-up analysis:', error);
        res.status(500).json({ error: 'Failed to process follow-up question' });
    } finally {
        // 5. Clean up temporary audio file
        if (tempAudioPath && fs.existsSync(tempAudioPath)) {
            try {
                fs.unlinkSync(tempAudioPath);
                console.log(`Deleted temporary audio file: ${tempAudioPath}`);
            } catch (cleanupError) {
                console.error(`Error deleting temporary audio file ${tempAudioPath}:`, cleanupError);
            }
        }
    }
});

// Simple route for testing server is running
app.get('/', (req, res) => {
    res.send('Go or No Backend is running!');
});

app.listen(port, () => {
    console.log(`Backend server listening on port ${port}`);
}); 