export async function pollCondition(checkCondition: () => Promise<boolean>, interval: number, maxAttempts: number): Promise<boolean> {
    let attempts = 0;

    const executePoll = async (): Promise<boolean> => {
        const result = await checkCondition();
        attempts++;

        if (result) {
            return true;
        } else if (attempts < maxAttempts) {
            await delay(interval);
            return executePoll();
        } else {
            return false;
        }
    };

    return executePoll();
}

export function delay(ms: number) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join(''); 