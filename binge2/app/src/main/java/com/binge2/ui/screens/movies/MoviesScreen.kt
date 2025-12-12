package com.binge2.ui.screens.movies

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.tv.foundation.lazy.list.TvLazyColumn
import com.binge2.data.models.Movie
import com.binge2.ui.components.ContentRow
import com.binge2.ui.components.ContextMenu
import com.binge2.ui.components.ContextMenuItem
import com.binge2.ui.components.DetailView

@Composable
fun MoviesScreen(
    viewModel: MoviesViewModel,
    modifier: Modifier = Modifier
) {
    val uiState by viewModel.uiState.collectAsState()
    var showContextMenu by remember { mutableStateOf(false) }
    var contextMenuMovie by remember { mutableStateOf<Movie?>(null) }

    Box(modifier = modifier.fillMaxSize()) {
        Column(modifier = Modifier.fillMaxSize()) {
            // Top 60% - Detail View
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(0.6f)
            ) {
                uiState.selectedMovie?.let { movie ->
                    DetailView(
                        title = movie.title,
                        overview = movie.overview,
                        backdropUrl = movie.getBackdropUrl(),
                        logoUrl = movie.getLogoUrl(),
                        releaseDate = movie.releaseDate
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
                    // Trending Movies
                    if (uiState.trendingMovies.isNotEmpty()) {
                        item {
                            ContentRow(
                                title = "Trending Movies",
                                items = uiState.trendingMovies,
                                onItemClick = { /* Movie click - show details or play */ },
                                onItemLongClick = { movie ->
                                    contextMenuMovie = movie
                                    showContextMenu = true
                                },
                                onItemFocused = { movie ->
                                    viewModel.setSelectedMovie(movie)
                                },
                                posterUrl = { it.getPosterUrl() },
                                itemTitle = { it.title }
                            )
                        }
                    }

                    // Popular Movies
                    if (uiState.popularMovies.isNotEmpty()) {
                        item {
                            ContentRow(
                                title = "Popular Movies",
                                items = uiState.popularMovies,
                                onItemClick = { /* Movie click - show details or play */ },
                                onItemLongClick = { movie ->
                                    contextMenuMovie = movie
                                    showContextMenu = true
                                },
                                onItemFocused = { movie ->
                                    viewModel.setSelectedMovie(movie)
                                },
                                posterUrl = { it.getPosterUrl() },
                                itemTitle = { it.title }
                            )
                        }
                    }

                    // Continue Watching
                    if (uiState.continueWatching.isNotEmpty()) {
                        item {
                            ContentRow(
                                title = "Continue Watching",
                                items = uiState.continueWatching,
                                onItemClick = { /* Movie click - resume playback */ },
                                onItemLongClick = { movie ->
                                    contextMenuMovie = movie
                                    showContextMenu = true
                                },
                                onItemFocused = { movie ->
                                    viewModel.setSelectedMovie(movie)
                                },
                                posterUrl = { it.getPosterUrl() },
                                itemTitle = { it.title }
                            )
                        }
                    }

                    // Movie Watchlist
                    if (uiState.watchlist.isNotEmpty()) {
                        item {
                            ContentRow(
                                title = "Movie Watchlist",
                                items = uiState.watchlist,
                                onItemClick = { /* Movie click - show details or play */ },
                                onItemLongClick = { movie ->
                                    contextMenuMovie = movie
                                    showContextMenu = true
                                },
                                onItemFocused = { movie ->
                                    viewModel.setSelectedMovie(movie)
                                },
                                posterUrl = { it.getPosterUrl() },
                                itemTitle = { it.title }
                            )
                        }
                    }

                    // Genres
                    uiState.genres.forEach { genre ->
                        item {
                            // For each genre, you'd fetch movies by genre
                            // This is a placeholder
                            ContentRow(
                                title = genre.name,
                                items = emptyList<Movie>(),
                                onItemClick = { },
                                onItemLongClick = { movie ->
                                    contextMenuMovie = movie
                                    showContextMenu = true
                                },
                                onItemFocused = { movie ->
                                    viewModel.setSelectedMovie(movie)
                                },
                                posterUrl = { it.getPosterUrl() },
                                itemTitle = { it.title }
                            )
                        }
                    }
                }
            }
        }

        // Context Menu
        if (showContextMenu && contextMenuMovie != null) {
            val movie = contextMenuMovie!!
            ContextMenu(
                items = listOf(
                    ContextMenuItem("Mark as Watched") {
                        viewModel.toggleWatched(movie)
                    },
                    ContextMenuItem("Add to Watchlist") {
                        viewModel.toggleWatchlist(movie)
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
