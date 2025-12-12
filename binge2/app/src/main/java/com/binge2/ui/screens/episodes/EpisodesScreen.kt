package com.binge2.ui.screens.episodes

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.tv.foundation.lazy.list.TvLazyColumn
import com.binge2.data.models.Episode
import com.binge2.data.models.Season
import com.binge2.data.repository.TvRepository
import com.binge2.data.repository.UserDataRepository
import com.binge2.ui.components.ContentRow
import com.binge2.ui.components.ContextMenu
import com.binge2.ui.components.ContextMenuItem
import com.binge2.ui.components.DetailView
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

data class EpisodesUiState(
    val season: Season? = null,
    val episodes: List<Episode> = emptyList(),
    val selectedEpisode: Episode? = null,
    val currentUserId: Long = 1L,
    val isLoading: Boolean = false
)

class EpisodesViewModel(
    private val tvRepository: TvRepository,
    private val userDataRepository: UserDataRepository,
    private val showId: Int,
    private val seasonNumber: Int
) : ViewModel() {

    private val _uiState = MutableStateFlow(EpisodesUiState())
    val uiState: StateFlow<EpisodesUiState> = _uiState.asStateFlow()

    init {
        loadEpisodes()
    }

    private fun loadEpisodes() {
        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true) }

            val season = tvRepository.getSeasonDetails(showId, seasonNumber)
            val episodes = season?.episodes ?: emptyList()

            _uiState.update {
                it.copy(
                    season = season,
                    episodes = episodes,
                    selectedEpisode = episodes.firstOrNull(),
                    isLoading = false
                )
            }
        }
    }

    fun setSelectedEpisode(episode: Episode) {
        _uiState.update { it.copy(selectedEpisode = episode) }
    }

    fun toggleWatched(episode: Episode) {
        viewModelScope.launch {
            val isWatched = userDataRepository.isEpisodeWatched(
                _uiState.value.currentUserId,
                episode.id
            )
            if (isWatched) {
                userDataRepository.markEpisodeAsUnwatched(
                    _uiState.value.currentUserId,
                    episode.id
                )
            } else {
                userDataRepository.markEpisodeAsWatched(
                    _uiState.value.currentUserId,
                    showId,
                    episode.id,
                    episode.seasonNumber,
                    episode.episodeNumber
                )
            }
        }
    }
}

@Composable
fun EpisodesScreen(
    showId: Int,
    seasonNumber: Int,
    viewModel: EpisodesViewModel,
    onBackClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val uiState by viewModel.uiState.collectAsState()
    var showContextMenu by remember { mutableStateOf(false) }
    var contextMenuEpisode by remember { mutableStateOf<Episode?>(null) }

    Box(modifier = modifier.fillMaxSize()) {
        Column(modifier = Modifier.fillMaxSize()) {
            // Top 60% - Detail View
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(0.6f)
            ) {
                uiState.selectedEpisode?.let { episode ->
                    DetailView(
                        title = episode.name,
                        overview = episode.overview,
                        backdropUrl = episode.getStillUrl(),
                        logoUrl = null,
                        releaseDate = episode.airDate,
                        seasonNumber = episode.seasonNumber,
                        episodeNumber = episode.episodeNumber
                    )
                }
            }

            // Bottom 40% - Episodes List
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(0.4f)
            ) {
                TvLazyColumn(
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    // Add "Up a level" option
                    item {
                        ContentRow(
                            title = "Navigation",
                            items = listOf("Up a level"),
                            onItemClick = { onBackClick() },
                            onItemLongClick = { },
                            onItemFocused = { },
                            posterUrl = { null },
                            itemTitle = { it }
                        )
                    }

                    // Episodes
                    if (uiState.episodes.isNotEmpty()) {
                        item {
                            ContentRow(
                                title = "Episodes",
                                items = uiState.episodes,
                                onItemClick = { /* Play episode */ },
                                onItemLongClick = { episode ->
                                    contextMenuEpisode = episode
                                    showContextMenu = true
                                },
                                onItemFocused = { episode ->
                                    viewModel.setSelectedEpisode(episode)
                                },
                                posterUrl = { it.getStillUrl() },
                                itemTitle = { "E${it.episodeNumber}: ${it.name}" }
                            )
                        }
                    }
                }
            }
        }

        // Context Menu
        if (showContextMenu && contextMenuEpisode != null) {
            val episode = contextMenuEpisode!!
            ContextMenu(
                items = listOf(
                    ContextMenuItem("Mark as Watched") {
                        viewModel.toggleWatched(episode)
                    },
                    ContextMenuItem("View Cast & Crew") {
                        // TODO: Implement
                    }
                ),
                onDismiss = { showContextMenu = false }
            )
        }
    }
}
