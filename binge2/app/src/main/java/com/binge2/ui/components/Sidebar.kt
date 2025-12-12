package com.binge2.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.tv.foundation.lazy.list.TvLazyColumn
import androidx.tv.foundation.lazy.list.items
import androidx.tv.material3.Card
import androidx.tv.material3.CardDefaults
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.binge2.ui.theme.Surface

data class MenuItem(
    val title: String,
    val route: String
)

@Composable
fun Sidebar(
    visible: Boolean,
    onVisibilityChange: (Boolean) -> Unit,
    currentRoute: String,
    onMenuItemClick: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    val menuItems = listOf(
        MenuItem("Movies", "movies"),
        MenuItem("Shows", "shows"),
        MenuItem("Users", "user_selection")
    )

    AnimatedVisibility(
        visible = visible,
        enter = slideInHorizontally(),
        exit = slideOutHorizontally(),
        modifier = modifier
    ) {
        Box(
            modifier = Modifier
                .width(250.dp)
                .fillMaxHeight()
                .background(Surface.copy(alpha = 0.95f))
        ) {
            TvLazyColumn(
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                item {
                    Text(
                        text = "BINGE2",
                        style = MaterialTheme.typography.headlineMedium,
                        color = Color.White,
                        modifier = Modifier.padding(vertical = 16.dp)
                    )
                }

                items(menuItems) { item ->
                    Card(
                        onClick = {
                            onMenuItemClick(item.route)
                            onVisibilityChange(false)
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .onFocusChanged { focusState ->
                                if (focusState.isFocused) {
                                    onVisibilityChange(true)
                                }
                            },
                        colors = CardDefaults.colors(
                            containerColor = if (currentRoute == item.route) {
                                MaterialTheme.colorScheme.primary
                            } else {
                                MaterialTheme.colorScheme.surfaceVariant
                            }
                        )
                    ) {
                        Text(
                            text = item.title,
                            style = MaterialTheme.typography.titleMedium,
                            modifier = Modifier.padding(16.dp)
                        )
                    }
                }
            }
        }
    }
}
