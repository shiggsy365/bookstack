package com.binge2.ui.screens.shows

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.tv.foundation.lazy.list.TvLazyColumn
import com.binge2.data.models.TvShow
import com.binge2.ui.components.ContentRow
import com.binge2.ui.components.ContextMenu
import com.binge2.ui.components.ContextMenuItem
import com.binge2.ui.components.DetailView

@Composable
fun ShowsScreen(
    viewModel: ShowsViewModel,
    onShowClick: (Int) -> Unit,
    modifier: Modifier = Modifier
) {
    val uiState by viewModel.uiState.collectAsState()
    var showContextMenu by remember { mutableStateOf(false) }
    var contextMenuShow by remember { mutableStateOf<TvShow?>(null) }

    Box(modifier = modifier.fillMaxSize()) {
        Column(modifier = Modifier.fillMaxSize()) {
            // Top 60% - Detail View
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(0.6f)
            ) {
                uiState.selectedShow?.let { show ->
                    DetailView(
                        title = show.name,
                        overview = show.overview,
                        backdropUrl = show.getBackdropUrl(),
                        logoUrl = show.getLogoUrl(),
                        releaseDate = show.firstAirDate
                    )
                }
            }

            // Bottom 40% - Content Rows
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(0.4f)
            ) {
                TvLazyColumn(
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    // Up Next
                    if (uiState.upNext.isNotEmpty()) {
                        item {
                            ContentRow(
                                title = "Up Next",
                                items = uiState.upNext,
                                onItemClick = { onShowClick(it.id) },
                                onItemLongClick = { show ->
                                    contextMenuShow = show
                                    showContextMenu = true
                                },
                                onItemFocused = { show ->
                                    viewModel.setSelectedShow(show)
                                },
                                posterUrl = { it.getPosterUrl() },
                                itemTitle = { it.name }
                            )
                        }
                    }

                    // Trending Shows
                    if (uiState.trendingShows.isNotEmpty()) {
                        item {
                            ContentRow(
                                title = "Trending Shows",
                                items = uiState.trendingShows,
                                onItemClick = { onShowClick(it.id) },
                                onItemLongClick = { show ->
                                    contextMenuShow = show
                                    showContextMenu = true
                                },
                                onItemFocused = { show ->
                                    viewModel.setSelectedShow(show)
                                },
                                posterUrl = { it.getPosterUrl() },
                                itemTitle = { it.name }
                            )
                        }
                    }

                    // Popular Shows
                    if (uiState.popularShows.isNotEmpty()) {
                        item {
                            ContentRow(
                                title = "Popular Shows",
                                items = uiState.popularShows,
                                onItemClick = { onShowClick(it.id) },
                                onItemLongClick = { show ->
                                    contextMenuShow = show
                                    showContextMenu = true
                                },
                                onItemFocused = { show ->
                                    viewModel.setSelectedShow(show)
                                },
                                posterUrl = { it.getPosterUrl() },
                                itemTitle = { it.name }
                            )
                        }
                    }

                    // Continue Watching
                    if (uiState.continueWatching.isNotEmpty()) {
                        item {
                            ContentRow(
                                title = "Continue Watching",
                                items = uiState.continueWatching,
                                onItemClick = { onShowClick(it.id) },
                                onItemLongClick = { show ->
                                    contextMenuShow = show
                                    showContextMenu = true
                                },
                                onItemFocused = { show ->
                                    viewModel.setSelectedShow(show)
                                },
                                posterUrl = { it.getPosterUrl() },
                                itemTitle = { it.name }
                            )
                        }
                    }

                    // TV Watchlist
                    if (uiState.watchlist.isNotEmpty()) {
                        item {
                            ContentRow(
                                title = "TV Watchlist",
                                items = uiState.watchlist,
                                onItemClick = { onShowClick(it.id) },
                                onItemLongClick = { show ->
                                    contextMenuShow = show
                                    showContextMenu = true
                                },
                                onItemFocused = { show ->
                                    viewModel.setSelectedShow(show)
                                },
                                posterUrl = { it.getPosterUrl() },
                                itemTitle = { it.name }
                            )
                        }
                    }

                    // Genres
                    uiState.genres.forEach { genre ->
                        item {
                            // For each genre, you'd fetch shows by genre
                            // This is a placeholder
                            ContentRow(
                                title = genre.name,
                                items = emptyList<TvShow>(),
                                onItemClick = { onShowClick(it.id) },
                                onItemLongClick = { show ->
                                    contextMenuShow = show
                                    showContextMenu = true
                                },
                                onItemFocused = { show ->
                                    viewModel.setSelectedShow(show)
                                },
                                posterUrl = { it.getPosterUrl() },
                                itemTitle = { it.name }
                            )
                        }
                    }
                }
            }
        }

        // Context Menu
        if (showContextMenu && contextMenuShow != null) {
            val show = contextMenuShow!!
            ContextMenu(
                items = listOf(
                    ContextMenuItem("Add to Watchlist") {
                        viewModel.toggleWatchlist(show)
                    },
                    ContextMenuItem("View Cast & Crew") {
                        // TODO: Implement
                    },
                    ContextMenuItem("View Similar") {
                        // TODO: Implement
                    }
                ),
                onDismiss = { showContextMenu = false }
            )
        }
    }
}
