#!/usr/bin/env node

// Convert a audio file to a different encoding and bitrates
// Specifically, opus, aac, ogg, and mp3, at 64, 96, 128, 160, 192, and 256 kbps

// You must have flac, opusenc, qaac, oggenc2, and lame installed.

const fs = require('fs');
const path = require('path');
const childProcess = require('child_process');

function log(msg) {
    // current time
    const now = new Date();
    const time = now.toLocaleTimeString();
    const date = now.toLocaleDateString();
    msg = `[${date} ${time}] ${msg}`;
    console.log(msg)
}

const inputFile = process.argv[2];

if (!inputFile) {
    log('No input file specified');
    process.exit(1);
}

if (path.extname(inputFile) !== '.wav') {
    log('Input file must be a .wav file');
    process.exit(1);
}

const markdown = "table.md"
// Open the log file
const markdownFp = fs.openSync(markdown, 'a');
function writeMd(msg) {
    fs.writeSync(markdownFp, msg)
}

process.on('exit', () => {
    fs.closeSync(markdownFp);
});

log("Markdown output: " + markdown)

const bitrateLevels = [
    64,
    96,
    128,
    160,
    192,
    256,
];

const qaacLevels = [
    27, // 64 kbps
    45, // 96 kbps
    64, // 128 kbps
    82, // 160 kbps
    91, // 192 kbps
    109, // 256 kbps
]

const oggLevels = [
    0, // 64 kbps
    2, // 96 kbps
    4, // 128 kbps
    5, // 160 kbps
    6, // 192 kbps
    8, // 256 kbps
]

const mp3Levels = [
    9, // 64 kbps
    7, // 96 kbps
    5, // 128 kbps
    4, // 160 kbps
    2, // 192 kbps
    0, // 256 kbps
]

function runCommand(cmd) {
    log("Run: " + cmd);
    const command = cmd.split(' ');
    const ch = childProcess.spawnSync(command[0], command.slice(1), { shell: true });
    const returnCode = ch.status;

    if (returnCode !== 0) {
        log("Previous command failed with return code: " + returnCode);
        log(ch.stdout?.toString());
        log(ch.stderr?.toString());
    }

    return ch.stdout?.toString()
}

function convert(inputFile, codec, bitrateLevel) {
    let outputFile = path.basename(inputFile, path.extname(inputFile)) + '.' + codec;
    let command;
    switch (codec) {
        case 'flac':
            command = `flac --best --verify --output-name=${outputFile} ${inputFile}`;
            break;
        case 'opus':
            command = `opusenc --bitrate ${bitrateLevels[bitrateLevel]} --vbr ${inputFile} ${outputFile}`;
            break;
        case 'aac':
            outputFile = path.basename(inputFile, path.extname(inputFile)) + '.m4a';
            command = `qaac -V ${qaacLevels[bitrateLevel]} -o ${outputFile} ${inputFile}`;
            break;
        case 'ogg':
            command = `oggenc2 -Q -q${oggLevels[bitrateLevel]} -o ${outputFile} ${inputFile}`;
            break;
        case 'mp3':
            command = `lame -V ${mp3Levels[bitrateLevel]} ${inputFile} ${outputFile}`;
            break;
        default:
            log(`Invalid codec: ${codec}`);
            process.exit(1);
    }
    if (fs.existsSync(outputFile)) {
        log(`Removing existing file: ${outputFile}`)
        fs.unlinkSync(outputFile);
    }
    log(`Converting ${inputFile} to ${outputFile} with ${codec} at ${bitrateLevels[bitrateLevel]} kbps`)
    runCommand(command);
    return outputFile
}

function rename(inputFile, codec, bitrateLevel, actualBitrateKbps) {
    let newOutputFile = path.basename(inputFile, path.extname(inputFile))
    switch (codec) {
        case 'flac':
            newOutputFile += `-flac-${actualBitrateKbps}k.flac`;
            break;
        case 'opus':
            newOutputFile += `-opus-vbr${bitrateLevels[bitrateLevel]}k-${actualBitrateKbps}k.opus`;
            break;
        case 'aac':
            newOutputFile += `-qaac-q${qaacLevels[bitrateLevel]}-${actualBitrateKbps}k.m4a`;
            break;
        case 'ogg':
            newOutputFile += `-vorbis-q${oggLevels[bitrateLevel]}-${actualBitrateKbps}k.ogg`;
            break;
        case 'mp3':
            newOutputFile += `-lame-v${mp3Levels[bitrateLevel]}-${actualBitrateKbps}k.mp3`;
            break;
        default:
            log(`Invalid codec: ${codec}`);
            process.exit(1);
    }

    if (fs.existsSync(newOutputFile)) {
        log(`Removing existing file: ${newOutputFile}`)
        fs.unlinkSync(newOutputFile);
    }
    log(`Renaming ${inputFile} to ${newOutputFile}`)
    fs.renameSync(inputFile, newOutputFile);
    return newOutputFile
}

function probeBitrateKbps(inputFile) {
    let command;
    switch (path.extname(inputFile)) {
        case '.flac':
            command = `ffprobe -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 ${inputFile}`;
            break;
        case '.opus':
            command = `ffprobe -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 ${inputFile}`;
            break;
        case '.m4a':
            command = `ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 ${inputFile}`;
            break;
        case '.ogg':
            command = `ffprobe -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 ${inputFile}`;
            break;
        case '.mp3':
            command = `ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 ${inputFile}`;
            break;
        default:
            log(`Invalid file extension: ${path.extname(inputFile)}`);
            process.exit(1);
    }

    let bitrate = parseInt(runCommand(command));

    if (bitrate) {
        return Math.round(bitrate / 1000)
    }

    return 0
}

function genCell(caption, mime, name) {
    return `<figure>
<figcaption>${caption}</figcaption>
<audio 
style="margin:0 24px 0 24px;" 
controls 
loop 
preload="none" 
type="${mime}" 
src="media/${name}" />
</figure>`
}

function genOpusCell(name, kbps, bitrateLevel) {
    return genCell(`opusenc, vbr${bitrateLevels[bitrateLevel]}, ${kbps}k`, "audio/ogg", name).replaceAll('\n', '')
}

function genAacCell(name, kbps, bitrateLevel) {
    return genCell(`qaac, q${qaacLevels[bitrateLevel]}, ${kbps}k`, "audio/mp4", name).replaceAll('\n', '')
}

function genOggCell(name, kbps, bitrateLevel) {
    return genCell(`oggenc2, q${oggLevels[bitrateLevel]}, ${kbps}k`, "audio/ogg", name).replaceAll('\n', '')
}

function genMp3Cell(name, kbps, bitrateLevel) {
    return genCell(`lame, v${mp3Levels[bitrateLevel]}, ${kbps}k`, "audio/mpeg", name).replaceAll('\n', '')
}

let lastFilename, lastBitrateKbps;

function convertFlac() {
    lastFilename = convert(inputFile, 'flac', 0);
    lastBitrateKbps = probeBitrateKbps(lastFilename);
    lastFilename = rename(lastFilename, 'flac', 0, lastBitrateKbps);
}

function convertOpus(bitrateLevel) {
    lastFilename = convert(inputFile, 'opus', bitrateLevel);
    lastBitrateKbps = probeBitrateKbps(lastFilename);
    lastFilename = rename(lastFilename, 'opus', bitrateLevel, lastBitrateKbps);
}

function convertAac(bitrateLevel) {
    lastFilename = convert(inputFile, 'aac', bitrateLevel);
    lastBitrateKbps = probeBitrateKbps(lastFilename);
    lastFilename = rename(lastFilename, 'aac', bitrateLevel, lastBitrateKbps);
}

function convertOgg(bitrateLevel) {
    lastFilename = convert(inputFile, 'ogg', bitrateLevel);
    lastBitrateKbps = probeBitrateKbps(lastFilename);
    lastFilename = rename(lastFilename, 'ogg', bitrateLevel, lastBitrateKbps);
}

function convertMp3(bitrateLevel) {
    lastFilename = convert(inputFile, 'mp3', bitrateLevel);
    lastBitrateKbps = probeBitrateKbps(lastFilename);
    lastFilename = rename(lastFilename, 'mp3', bitrateLevel, lastBitrateKbps);
}

convertFlac()
writeMd(genCell(`flac, best, ${lastBitrateKbps}k`, "audio/flac", lastFilename) + "\n\n")

writeMd(`| VBR Bitrate | Opus | AAC | Ogg | MP3 |
| ----------- | ---- | --- | --- | --- |
`)

for (let i = bitrateLevels.length - 1; i >= 0; i--) {
    writeMd(`| ~${bitrateLevels[i]}k | `)

    convertOpus(i);
    writeMd(genOpusCell(lastFilename, lastBitrateKbps, i))
    writeMd(' | ')

    convertAac(i);
    writeMd(genAacCell(lastFilename, lastBitrateKbps, i))
    writeMd(' | ')

    convertOgg(i);
    writeMd(genOggCell(lastFilename, lastBitrateKbps, i))
    writeMd(' | ')

    convertMp3(i);
    writeMd(genMp3Cell(lastFilename, lastBitrateKbps, i))
    writeMd(' | \n')
}

writeMd('\n')
