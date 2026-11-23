// The legacy runtime shares the standard API; its upstream .d.mts re-export
// does not resolve the package self-reference under bundler module resolution.
declare module 'pdfjs-dist/legacy/build/pdf.mjs' {
    export const getDocument: typeof import('pdfjs-dist').getDocument
    export const GlobalWorkerOptions: typeof import('pdfjs-dist').GlobalWorkerOptions
    export type PDFDocumentProxy = import('pdfjs-dist').PDFDocumentProxy
}
