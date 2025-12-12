# BINGE2 - Android TV Streaming App

A modern, sleek Android TV streaming application built with Jetpack Compose for TV and Kotlin.

## Features

### Content Pages

#### Movies Page
- **Trending Movies** - Discover what's popular right now
- **Popular Movies** - All-time popular films
- **Continue Watching** - Resume where you left off
- **Movie Watchlist** - Your saved movies
- **Genres** - Browse by category

#### Shows Page
- **Up Next** - Your next episode to watch
- **Trending Shows** - What's hot on TV
- **Popular Shows** - Fan favorites
- **Continue Watching** - Resume your series
- **TV Watchlist** - Your saved shows
- **Genres** - Browse by category

### User Interface

- **60/40 Layout** - Top 60% displays detailed information about the focused item (backdrop, logo, release date, episode info, description). Bottom 40% shows horizontal scrolling poster lists
- **Auto-Hide Sidebar** - Left-side menu that appears on back button press
- **Focus-Based Navigation** - TV-optimized D-pad navigation
- **Context Menu** - Long-press for options:
  - Mark as watched/unwatched
  - Add/remove from watchlist
  - View cast and crew
  - View similar content

### Navigation

- **Movies** - Click to view details (streaming to be implemented)
- **Shows** - Drill down through: Show → Seasons → Episodes
- **Up a Level** - Navigate back through the hierarchy

### Multi-User Support

- Create and manage multiple user profiles
- Each user has their own:
  - Watchlist
  - Watch history
  - Continue watching progress
  - Watched status tracking

## Technical Stack

- **Language**: Kotlin
- **UI Framework**: Jetpack Compose for TV
- **Architecture**: MVVM (Model-View-ViewModel)
- **Database**: Room (SQLite)
- **API Client**: Retrofit + OkHttp
- **Image Loading**: Coil
- **Navigation**: Jetpack Navigation Compose
- **Data Source**: The Movie Database (TMDB) API

## Project Structure

```
binge2/
├── app/
│   ├── src/main/
│   │   ├── java/com/binge2/
│   │   │   ├── data/
│   │   │   │   ├── api/          # TMDB API service
│   │   │   │   ├── database/     # Room database, DAOs, entities
│   │   │   │   ├── models/       # Data models
│   │   │   │   └── repository/   # Data repositories
│   │   │   ├── ui/
│   │   │   │   ├── components/   # Reusable UI components
│   │   │   │   ├── navigation/   # Navigation setup
│   │   │   │   ├── screens/      # App screens
│   │   │   │   └── theme/        # App theme
│   │   │   └── MainActivity.kt
│   │   ├── res/                  # Resources
│   │   └── AndroidManifest.xml
│   └── build.gradle.kts
├── secrets.properties            # API keys (not committed)
├── build.gradle.kts
└── settings.gradle.kts
```

## Setup

### Prerequisites

- Android Studio Hedgehog (2023.1.1) or later
- Android SDK with API level 28+ (Android 9.0 Pie) for TV
- TMDB API account

### Installation

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd binge2
   ```

2. **Configure TMDB API**

   The `secrets.properties` file is already configured with API credentials:
   ```properties
   TMDB_API_KEY=a77304e2ead90e385dce678b4e530a40
   TMDB_ACCESS_TOKEN=eyJhbGciOiJIUzI1NiJ9...
   ```

3. **Open in Android Studio**
   - Open Android Studio
   - Select "Open an Existing Project"
   - Navigate to the `binge2` folder

4. **Sync Gradle**
   - Android Studio should automatically sync Gradle
   - If not, click "Sync Project with Gradle Files"

5. **Run the app**
   - Select an Android TV emulator or device
   - Click Run

## API Endpoints Used

The app uses the following TMDB API endpoints:

- `GET /discover/movie` - Trending and popular movies
- `GET /discover/tv` - Trending and popular TV shows
- `GET /movie/{id}` - Movie details
- `GET /tv/{id}` - TV show details
- `GET /tv/{id}/season/{season}` - Season and episode details
- `GET /genre/movie/list` - Movie genres
- `GET /genre/tv/list` - TV show genres

## Database Schema

### Users Table
- Stores user profiles for multi-user support

### Watchlist Table
- Tracks movies and shows added to each user's watchlist

### Watched Table
- Records watched movies and episodes per user

### Continue Watching Table
- Stores playback position and progress for resuming content

## Future Enhancements

- [ ] Video playback integration
- [ ] Cast and crew details screen
- [ ] Similar content recommendations
- [ ] Search functionality
- [ ] Advanced filters and sorting
- [ ] Parental controls
- [ ] Download for offline viewing
- [ ] Subtitle support
- [ ] Multiple language support
- [ ] User avatars

## Contributing

This is a demonstration project. Feel free to fork and modify as needed.

## License

This project uses the TMDB API but is not endorsed or certified by TMDB.

## Acknowledgments

- **The Movie Database (TMDB)** for providing the comprehensive movie and TV data API
- **Jetpack Compose** team for the excellent TV framework
