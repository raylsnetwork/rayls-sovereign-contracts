import * as fs from "node:fs";

function getEnvEntryPrefix(key: string): string {
    return `${key}=`;
}

function readEnvFileLines(envFilePath: string): string[] | undefined {
    if (!fs.existsSync(envFilePath)) {
        return undefined;
    }

    const envContent = fs.readFileSync(envFilePath, "utf8");
    const lines = envContent.split(/\r?\n/);

    if (lines[lines.length - 1] === "") {
        lines.pop();
    }

    return lines;
}

export function getEnvVariableFromFile(
    envFilePath: string,
    key: string,
): string | undefined {
    const lines = readEnvFileLines(envFilePath);

    if (!lines) {
        return undefined;
    }

    const entryPrefix = getEnvEntryPrefix(key);

    for (const line of lines) {
        const trimmedLine = line.trim();
        if (trimmedLine.length === 0 || trimmedLine.startsWith("#")) {
            continue;
        }

        if (trimmedLine.startsWith(entryPrefix)) {
            const value = trimmedLine.slice(entryPrefix.length).trim();
            return value.length > 0 ? value : undefined;
        }
    }

    return undefined;
}

export function upsertEnvVariable(
    envFilePath: string,
    key: string,
    value: string,
): void {
    const lines = readEnvFileLines(envFilePath) ?? [];
    const entryPrefix = getEnvEntryPrefix(key);
    const entry = `${entryPrefix}${value}`;
    const entryLineIndex = lines.findIndex((line) => line.trimStart().startsWith(entryPrefix));

    if (entryLineIndex >= 0) {
        lines[entryLineIndex] = entry;
    } else {
        lines.push(entry);
    }

    fs.writeFileSync(envFilePath, `${lines.join("\n")}\n`, "utf8");
}
