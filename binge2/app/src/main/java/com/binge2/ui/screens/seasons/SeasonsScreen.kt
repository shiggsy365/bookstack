package com.binge2.ui.screens.seasons

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.tv.foundation.lazy.list.TvLazyColumn
import com.binge2.data.models.Season
import com.binge2.data.models.TvShow
import com.binge2.data.repository.TvRepository
import com.binge2.ui.components.ContentRow
import com.binge2.ui.components.DetailView
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

data class SeasonsUiState(
    val show: TvShow? = null,
    val seasons: List<Season> = emptyList(),
    val selectedSeason: Season? = null,
    val isLoading: Boolean = false
)

class SeasonsViewModel(
    private val tvRepository: TvRepository,
    private val showId: Int
) : ViewModel() {

    private val _uiState = MutableStateFlow(SeasonsUiState())
    val uiState: StateFlow<SeasonsUiState> = _uiState.asStateFlow()

    init {
        loadShow()
    }

    private fun loadShow() {
        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true) }

            val show = tvRepository.getTvShowDetails(showId)
            val seasons = show?.seasons?.filter { it.seasonNumber > 0 } ?: emptyList()

            _uiState.update {
                it.copy(
                    show = show,
                    seasons = seasons,
                    selectedSeason = seasons.firstOrNull(),
                    isLoading = false
                )
            }
        }
    }

    fun setSelectedSeason(season: Season) {
        _uiState.update { it.copy(selectedSeason = season) }
    }
}

@Composable
fun SeasonsScreen(
    showId: Int,
    viewModel: SeasonsViewModel,
    onSeasonClick: (Int, Int) -> Unit,
    onBackClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val uiState by viewModel.uiState.collectAsState()

    Box(modifier = modifier.fillMaxSize()) {
        Column(modifier = Modifier.fillMaxSize()) {
            // Top 60% - Detail View
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(0.6f)
            ) {
                uiState.selectedSeason?.let { season ->
                    DetailView(
                        title = season.name,
                        overview = season.overview,
                        backdropUrl = uiState.show?.getBackdropUrl(),
                        logoUrl = season.getPosterUrl(),
                        releaseDate = season.airDate,
                        seasonNumber = season.seasonNumber,
                        episodeNumber = null
                    )
                }
            }

            // Bottom 40% - Seasons List
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

                    // Seasons
                    if (uiState.seasons.isNotEmpty()) {
                        item {
                            ContentRow(
                                title = "Seasons",
                                items = uiState.seasons,
                                onItemClick = { season ->
                                    onSeasonClick(showId, season.seasonNumber)
                                },
                                onItemLongClick = { },
                                onItemFocused = { season ->
                                    viewModel.setSelectedSeason(season)
                                },
                                posterUrl = { it.getPosterUrl() },
                                itemTitle = { it.name }
                            )
                        }
                    }
                }
            }
        }
    }
}
