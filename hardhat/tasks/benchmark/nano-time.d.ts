// types/nano-time.d.ts
declare module 'nano-time' {
    // Default export is the `nanoseconds()` function
    function nanoseconds(): string;

    // Add namespace for `.microseconds()` and `.micro()` methods
    namespace nanoseconds {
        function microseconds(): string;
        function micro(): string;
    }

    // Export the function as default and include the namespace
    export = nanoseconds;
}