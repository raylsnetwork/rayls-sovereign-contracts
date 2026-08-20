export class Logger {
    public BOLD = `\x1b[1m`;
    public BLINK = `\x1b[5m`;
    public RED = `\x1b[31m`;
    public GREEN = `\x1b[32m`;
    public YELLOW = `\x1b[33m`;
    public CYAN = `\x1b[36m`;
    public GRAY = `\x1b[90m`;
    public RESET = `\x1b[0m`;
    public INFO = this.GRAY;
    public ERROR = this.RED;
    public DATA = this.CYAN;
    public SUCCESS = this.GREEN;

    private interval?: NodeJS.Timeout;
    private currentMessage?: string;
    private startTime?: DOMHighResTimeStamp;

    constructor() {}

    private date() {
        return `${this.INFO}${new Date().toISOString()} -> ${this.RESET}`;
    }

    log(message: string, mode: string = "") {
        console.log(`${this.date()}${mode}${message}${this.RESET}`);
    }

    info(message: string) {
        this.log(message, this.INFO);
    }

    data(message: string) {
        this.log(message, this.DATA);
    }

    success(message: string) {
        this.log(message, this.SUCCESS);
    }

    error(message: string) {
        this.log(message, this.ERROR);
    }
    
    load(message: string) {
        if (this.currentMessage) this.loadError();
        this.startTime = performance.now();

        const spinnerFrames = ['|', '/', '—', '\\'];
        let spinnerIndex = 0;

        this.interval = setInterval(() => {
            process.stdout.write(`\r${this.date()}${message} ${this.YELLOW}${spinnerFrames[spinnerIndex++ % spinnerFrames.length]}${this.RESET}`);
        }, 100);

        this.currentMessage = message;
    }

    finishLoad(message: string) {
        const endTime = performance.now();

        clearInterval(this.interval);
        this.interval = undefined;

        process.stdout.write(`\r${this.date()}${this.currentMessage} — ${message} [${Math.round(endTime - this.startTime!)/1000} s]\n`);

        this.currentMessage = undefined;
    }

    loadSuccess() {
        this.finishLoad(`${this.GREEN}${this.BOLD}SUCCESS${this.RESET}`);
    }

    loadError() {
        this.finishLoad(`${this.RED}${this.BOLD}ERROR${this.RESET}`);
    }
}