/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{vue,js,ts,jsx,tsx}'],
  theme: {
    extend: {
      colors: {
        // Apporo gold. DEFAULT (= 600) is the primary colour: white text on it
        // and it as text on white or cream both pass WCAG AA. On gold tints
        // (50/100, brand/10) use 700 or darker for text; 700 is also the hover
        // shade, the same as the Apporo platform's primary-hover.
        brand: {
          DEFAULT: '#8B6B24',
          50: '#FBF8F2',
          100: '#F6F1E6',
          200: '#EADFC6',
          300: '#D9C391',
          600: '#8B6B24',
          700: '#6F561D',
          800: '#57441A',
          900: '#3D3013',
        },
        // Body text and the warm page background.
        ink: '#212121',
        cream: '#FBF8F2',
      },
      fontFamily: {
        // Wordmark face: Poppins when the system has it; nothing is downloaded,
        // so the GUI keeps working offline and makes no third-party requests.
        display: [
          'Poppins',
          'ui-sans-serif',
          'system-ui',
          '-apple-system',
          '"Segoe UI"',
          'Roboto',
          '"Helvetica Neue"',
          'Arial',
          'sans-serif',
        ],
      },
    },
  },
  plugins: [],
}
