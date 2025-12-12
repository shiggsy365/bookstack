package com.binge2.ui.screens.shows

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.binge2.data.models.Genre
import com.binge2.data.models.TvShow
import com.binge2.data.repository.TvRepository
import com.binge2.data.repository.UserDataRepository
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

data class ShowsUiState(
    val trendingShows: List<TvShow> = emptyList(),
    val popularShows: List<TvShow> = emptyList(),
    val upNext: List<TvShow> = emptyList(),
    val continueWatching: List<TvShow> = emptyList(),
    val watchlist: List<TvShow> = emptyList(),
    val genres: List<Genre> = emptyList(),
    val selectedShow: TvShow? = null,
    val currentUserId: Long = 1L,
    val isLoading: Boolean = false
)

class ShowsViewModel(
    private val tvRepository: TvRepository,
    private val userDataRepository: UserDataRepository
) : ViewModel() {

    private val _uiState = MutableStateFlow(ShowsUiState())
    val uiState: StateFlow<ShowsUiState> = _uiState.asStateFlow()

    init {
        loadShows()
    }

    fun setCurrentUser(userId: Long) {
        _uiState.update { it.copy(currentUserId = userId) }
        loadShows()
    }

    fun setSelectedShow(show: TvShow) {
        _uiState.update { it.copy(selectedShow = show) }
    }

    private fun loadShows() {
        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true) }

            // Load trending shows
            val trending = tvRepository.getTrendingTvShows()
            _uiState.update { it.copy(trendingShows = trending) }

            // Load popular shows
            val popular = tvRepository.getPopularTvShows()
            _uiState.update { it.copy(popularShows = popular) }

            // Load genres
            val genres = tvRepository.getTvGenres()
            _uiState.update { it.copy(genres = genres) }

            // Set initial selected show
            if (trending.isNotEmpty()) {
                _uiState.update { it.copy(selectedShow = trending.first()) }
            }

            _uiState.update { it.copy(isLoading = false) }

            // Observe watchlist
            userDataRepository.getTvWatchlist(_uiState.value.currentUserId)
                .collect { watchlistEntities ->
                    // In a real app, you'd fetch full show details for these
                }

            // Observe continue watching
            userDataRepository.getContinueWatching(_uiState.value.currentUserId)
                .collect { continueWatchingEntities ->
                    // In a real app, you'd fetch full show details for these
                }
        }
    }

    fun toggleWatchlist(show: TvShow) {
        viewModelScope.launch {
            val isInWatchlist = userDataRepository.isInWatchlist(
                _uiState.value.currentUserId,
                show.id,
                "tv"
            )
            if (isInWatchlist) {
                userDataRepository.removeFromWatchlist(
                    _uiState.value.currentUserId,
                    show.id,
                    "tv"
                )
            } else {
                userDataRepository.addToWatchlist(
                    _uiState.value.currentUserId,
                    show.id,
                    "tv",
                    show.name,
                    show.posterPath
                )
            }
        }
    }
}
