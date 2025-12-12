package com.binge2.ui.screens.movies

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.binge2.data.database.AppDatabase
import com.binge2.data.models.Genre
import com.binge2.data.models.Movie
import com.binge2.data.repository.MovieRepository
import com.binge2.data.repository.UserDataRepository
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

data class MoviesUiState(
    val trendingMovies: List<Movie> = emptyList(),
    val popularMovies: List<Movie> = emptyList(),
    val continueWatching: List<Movie> = emptyList(),
    val watchlist: List<Movie> = emptyList(),
    val genres: List<Genre> = emptyList(),
    val selectedMovie: Movie? = null,
    val currentUserId: Long = 1L,
    val isLoading: Boolean = false
)

class MoviesViewModel(
    private val movieRepository: MovieRepository,
    private val userDataRepository: UserDataRepository
) : ViewModel() {

    private val _uiState = MutableStateFlow(MoviesUiState())
    val uiState: StateFlow<MoviesUiState> = _uiState.asStateFlow()

    init {
        loadMovies()
    }

    fun setCurrentUser(userId: Long) {
        _uiState.update { it.copy(currentUserId = userId) }
        loadMovies()
    }

    fun setSelectedMovie(movie: Movie) {
        _uiState.update { it.copy(selectedMovie = movie) }
    }

    private fun loadMovies() {
        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true) }

            // Load trending movies
            val trending = movieRepository.getTrendingMovies()
            _uiState.update { it.copy(trendingMovies = trending) }

            // Load popular movies
            val popular = movieRepository.getPopularMovies()
            _uiState.update { it.copy(popularMovies = popular) }

            // Load genres
            val genres = movieRepository.getMovieGenres()
            _uiState.update { it.copy(genres = genres) }

            // Set initial selected movie
            if (trending.isNotEmpty()) {
                _uiState.update { it.copy(selectedMovie = trending.first()) }
            }

            _uiState.update { it.copy(isLoading = false) }

            // Observe watchlist
            userDataRepository.getMovieWatchlist(_uiState.value.currentUserId)
                .collect { watchlistEntities ->
                    // In a real app, you'd fetch full movie details for these
                    // For now, just update the state
                }

            // Observe continue watching
            userDataRepository.getContinueWatching(_uiState.value.currentUserId)
                .collect { continueWatchingEntities ->
                    // In a real app, you'd fetch full movie details for these
                    // For now, just update the state
                }
        }
    }

    fun toggleWatchlist(movie: Movie) {
        viewModelScope.launch {
            val isInWatchlist = userDataRepository.isInWatchlist(
                _uiState.value.currentUserId,
                movie.id,
                "movie"
            )
            if (isInWatchlist) {
                userDataRepository.removeFromWatchlist(
                    _uiState.value.currentUserId,
                    movie.id,
                    "movie"
                )
            } else {
                userDataRepository.addToWatchlist(
                    _uiState.value.currentUserId,
                    movie.id,
                    "movie",
                    movie.title,
                    movie.posterPath
                )
            }
        }
    }

    fun toggleWatched(movie: Movie) {
        viewModelScope.launch {
            val isWatched = userDataRepository.isMovieWatched(
                _uiState.value.currentUserId,
                movie.id
            )
            if (isWatched) {
                userDataRepository.markMovieAsUnwatched(
                    _uiState.value.currentUserId,
                    movie.id
                )
            } else {
                userDataRepository.markMovieAsWatched(
                    _uiState.value.currentUserId,
                    movie.id
                )
            }
        }
    }
}
